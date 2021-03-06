#!/usr/bin/env bash

# Get script dir
# See: http://stackoverflow.com/a/29835459/4449544
rreadlink() ( # Execute the function in a *subshell* to localize variables and the effect of `cd`.

	target=$1 fname= targetDir= CDPATH=

	# Try to make the execution environment as predictable as possible:
	# All commands below are invoked via `command`, so we must make sure that `command`
	# itself is not redefined as an alias or shell function.
	# (Note that command is too inconsistent across shells, so we don't use it.)
	# `command` is a *builtin* in bash, dash, ksh, zsh, and some platforms do not even have
	# an external utility version of it (e.g, Ubuntu).
	# `command` bypasses aliases and shell functions and also finds builtins
	# in bash, dash, and ksh. In zsh, option POSIX_BUILTINS must be turned on for that
	# to happen.
	{ \unalias command; \unset -f command; } >/dev/null 2>&1
	[ -n "$ZSH_VERSION" ] && options[POSIX_BUILTINS]=on # make zsh find *builtins* with `command` too.

	while :; do # Resolve potential symlinks until the ultimate target is found.
			[ -L "$target" ] || [ -e "$target" ] || { command printf '%s\n' "ERROR: '$target' does not exist." >&2; return 1; }
			command cd "$(command dirname -- "$target")" # Change to target dir; necessary for correct resolution of target path.
			fname=$(command basename -- "$target") # Extract filename.
			[ "$fname" = '/' ] && fname='' # !! curiously, `basename /` returns '/'
			if [ -L "$fname" ]; then
				# Extract [next] target path, which may be defined
				# *relative* to the symlink's own directory.
				# Note: We parse `ls -l` output to find the symlink target
				#       which is the only POSIX-compliant, albeit somewhat fragile, way.
				target=$(command ls -l "$fname")
				target=${target#* -> }
				continue # Resolve [next] symlink target.
			fi
			break # Ultimate target reached.
	done
	targetDir=$(command pwd -P) # Get canonical dir. path
	# Output the ultimate target's canonical path.
	# Note that we manually resolve paths ending in /. and /.. to make sure we have a normalized path.
	if [ "$fname" = '.' ]; then
		command printf '%s\n' "${targetDir%/}"
	elif  [ "$fname" = '..' ]; then
		# Caveat: something like /var/.. will resolve to /private (assuming /var@ -> /private/var), i.e. the '..' is applied
		# AFTER canonicalization.
		command printf '%s\n' "$(command dirname -- "${targetDir}")"
	else
		command printf '%s\n' "${targetDir%/}/$fname"
	fi
)

DIR=$(dirname -- "$(rreadlink "$0")")
token=""
domains=""
ipCount="0"
domainCount="0"
remarks=""
reInit="false"

export FILEDB_ROOT="/tmp/Dns.sh_Cache"
export PATH=$PATH:$DIR

[ ! -d ${FILEDB_ROOT} ] && mkdir -p $FILEDB_ROOT
# Get data
# arg: type data
apiPost() {
	local agent="shellDdns/0.1(tofuliang@gmail.com)"
	local inter="https://dnsapi.cn/${1:?'Info.Version'}"
	local param="login_token=${token}&format=json&${2}"

	wget --quiet --no-check-certificate --output-document=- --user-agent=$agent --post-data $param $inter
}

trimQuotes(){
	echo ${1}|sed 's/"//g' 2>/dev/null;
}

domainInit() {
	reInit="false"
	token=$(trimQuotes $(jq .token $DIR/dns.json));
	domains=$(jq '.domains|keys_unsorted' $DIR/dns.json);
	ipCount=$(jq '.ips|length' $DIR/dns.json);
	domainCount=$(echo $domains|jq '.|length-1');
	remarks=$(jq '.ips|keys_unsorted' $DIR/dns.json);

	for index in `seq 0 ${domainCount}`;do
		local domain=$(trimQuotes $(echo $domains|jq '.['$index']' ));
		local cacheTime="0"$(filedb get "$domain" "cache_time")
		if [ $cacheTime -gt 0 ];then
			echo "DNS Info Cached.";
			return 0
		fi

		local subDomains=$(jq '.domains."'${domain}'"' $DIR/dns.json);
		local subDomainCount=$(jq '.domains."'${domain}'"|length-1' $DIR/dns.json);
		local domainInfo=$(apiPost Domain.List "keyword=${domain}"|jq ".domains[0]")
		local domainId=$(echo $domainInfo|jq ".id" );
		filedb set "$domain" "domainId" "${domainId}"
		local records=$(apiPost Record.List "domain_id=${domainId}&record_type=A"|jq ".records")
		local recordCount=$(echo $records|jq '.|length-1');
		for subDomainIndex in `seq 0 $subDomainCount`;do
			local subDomain=$(trimQuotes $(jq '.domains."'${domain}'"['$subDomainIndex']' $DIR/dns.json))
			for recordindex in `seq 0 $recordCount`;do
				local recordDomain=$(trimQuotes $(echo $records|jq '.['$recordindex'].name'));
				if [ "$recordDomain" =  "$subDomain" ];then
					local domainInfo=$(echo $records|jq -c '.['$recordindex']')
					local subDomainRemark=$(trimQuotes $(jq '.remark' <<<$domainInfo ));
					local recordId=$(trimQuotes $(jq '.id' <<<$domainInfo ));
					filedb lpush "$domain" "_$subDomain" "$domainInfo"
					if [ "$subDomainRemark" = "" ];then
						local _subDomainIndex=$(( $(filedb llen $domain _$subDomain) - 1 ));
						local remark=$(trimQuotes $(jq '.['${_subDomainIndex}']' <<<${remarks} ));
						updateRemark "$domainId" "$recordId" "$remark"
						domainInfo=$(apiPost Record.Info "domain_id=${domainId}&record_id=${recordId}"|jq -c ".record"|sed 's/sub_domain/name/'|sed 's/record_//g' )
						filedb lpop "$domain" "_$subDomain"
						filedb lpush "$domain" "_$subDomain" "$domainInfo"
					fi
				fi
			done
			local subDomainMissIngCount=$(( $ipCount - $(( $(filedb llen "$domain" "_$subDomain") + 0 )) ));
			if [ ${subDomainMissIngCount} -gt "0" ];then
				for i in `seq 1 ${ipCount}`;do
					local remarkIndex=$(( $i - 1 ));
					local remark=$(trimQuotes $(jq '.['${remarkIndex}']' <<<${remarks} ));
					local c=$(filedb get "$domain" "_$subDomain"|grep \"remark\":\"${remark}\"|wc -l)
					if [ "0" = "${c}" ];then
						addRecord "$domainId" "$subDomain" "$remark"
						subDomainMissIngCount=$(( $subDomainMissIngCount - 1 ));
					fi
				done;
				
				if [ ${subDomainMissIngCount} -eq "0" ];then
					filedb flush-domain "$domain"
				fi
			fi
		done;
		if [ "$reInit" = "true" ]; then
			domainInit
		fi
		filedb set "$domain" "cache_time" "`date +%s`"
		echo "making DNS Info Cache."
	done;
}

addRecord() {
	local response
	reInit="true"
	echo "addRecord...";
	local ip=$( eval $(jq -r '.ips["'${3}'"]' $DIR/dns.json ))
	echo "domain_id=${1}&sub_domain=${2}&record_type=A&record_line=默认&value=${ip}"
	local response=$(apiPost Record.Create "domain_id=${1}&sub_domain=${2}&record_type=A&record_line=默认&value=${ip}")
	echo $response
	local recordId=$(trimQuotes $(jq '.record.id' <<<$response ));
	updateRemark "${1}" "$recordId" "$3"
	echo ""
}

updateRemark() {
	local response
	echo "updateRemark...";
	echo "domain_id=${1}&record_id=${2}&remark=${3}"
	local response=$(apiPost Record.Remark "domain_id=${1}&record_id=${2}&remark=${3}")
	echo ${response}
	echo ""
}

updateDomain() {
	local response
	echo "updateDomain...";
	echo "domain_id=${1}&record_id=${2}&record_type=A&value=${3}&record_line=默认&sub_domain=${4}";
	local response=$(apiPost "Record.Modify" "domain_id=${1}&record_id=${2}&record_type=A&value=${3}&record_line=默认&sub_domain=${4}")
	echo ${response}
	echo ""
}

checkDns() {
	for index in `seq 0 ${domainCount}`;do
		local domain=$(trimQuotes $(echo $domains|jq '.['$index']' ));
		local subDomains=$(jq '.domains."'${domain}'"' $DIR/dns.json);
		local subDomainCount=$(jq '.domains."'${domain}'"|length-1' $DIR/dns.json);
		local domainId=$(filedb get "$domain" "domainId")

		for subDomainIndex in `seq 0 $subDomainCount`;do
			local subDomain=$(trimQuotes $(jq '.domains."'${domain}'"['$subDomainIndex']' $DIR/dns.json))
			for subDomainCacheIndex in `seq 0 $(( $(filedb llen "$domain" "_$subDomain") -1 ))`;do
				local subDomainCache=$(filedb lindex "$domain" "_${subDomain}" "${subDomainCacheIndex}")
				local cacheIp=$(trimQuotes $(jq '.value' <<<$subDomainCache ));
				local remark=$(trimQuotes $(jq '.remark' <<<$subDomainCache ));
				local recordId=$(trimQuotes $(jq '.id' <<<$subDomainCache ));
				local ip=$( eval $(jq -r '.ips["'${remark}'"]' $DIR/dns.json ))
				if [ "0${ip}" != "0${cacheIp}" ];then
					updateDomain "${domainId}" "${recordId}"  "${ip}" "${subDomain}"					
					local domainInfo=$(apiPost Record.Info "domain_id=${domainId}&record_id=${recordId}"|jq -c ".record"|sed 's/sub_domain/name/'|sed 's/record_//g' )
					filedb lset "$domain" "_$subDomain" "${subDomainCacheIndex}" "$domainInfo";	
				fi
			done
		done;
	done;
	echo "checkDns Done.";
}

domainInit
checkDns

exit 0
