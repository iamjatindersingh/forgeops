#!/usr/bin/env bash
# Manage configurations for the ForgeRock platform. Copies configurations in git to the Docker/ folder
#    Can optionally export configuration from running products and copy it back to the git /config folder.
# This script is not supported by ForgeRock.
set -oe pipefail

## Start of arg parsing - originally generated by argbash.io
die()
{
	local _ret=$2
	test -n "$_ret" || _ret=1
	test "$_PRINT_HELP" = yes && print_help >&2
	echo "$1" >&2
	exit ${_ret}
}


begins_with_short_option()
{
	local first_option all_short_options='pch'
	first_option="${1:0:1}"
	test "$all_short_options" = "${all_short_options/$first_option/}" && return 1 || return 0
}

# THE DEFAULTS INITIALIZATION - POSITIONALS
_positionals=()
# THE DEFAULTS INITIALIZATION - OPTIONALS
_arg_component="all"

# Profile defaults to cdk if not provided
_arg_profile="${CDK_PROFILE:-cdk}"
_arg_version="${CDK_VERSION:-7.0}"

print_help()
{
	printf '%s\n' "manage ForgeRock platform configurations"
	printf 'Usage: %s [-p|--profile <arg>] [-c|--component <arg>] [-v|--version <arg>] [-h|--help] <operation>\n' "$0"
	printf '\t%s\n' "<operation>: operation is one of"
	printf '\t\t%s\n' "init   - to copy initial configuration. This deletes any existing configuration in docker/"
	printf '\t\t%s\n' "add    - to add to the configuration. Same as init, but will not remove existing configuration"
	printf '\t\t%s\n' "diff   - to run the git diff command"
	printf '\t\t%s\n' "export - export config from running instance"
	printf '\t\t%s\n' "save   - save to git"
	printf '\t\t%s\n' "restore - restore git (abandon changes)"
	printf '\t\t%s\n' "sync   - export and save"
	printf '\t%s\n' "-c, --component: Select component - am, amster, idm, ig or all  (default: 'all')"
	printf '\t%s\n' "-p, --profile: Select configuration source (default: 'cdk')"
	printf '\t%s\n' "-v, --version: Select configuration version (default: '7.0')"
	printf '\t%s\n' "-h, --help: Prints help"
	printf '\n%s\n' "example to copy idm files: config.sh -c idm -p cdk init"
}


parse_commandline()
{
	_positionals_count=0
	while test $# -gt 0
	do
		_key="$1"
		case "$_key" in
			-c|--component)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_component="$2"
				shift
				;;
			--component=*)
				_arg_component="${_key##--component=}"
				;;
			-c*)
				_arg_component="${_key##-c}"
				;;
			-p|--profile)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_profile="$2"
				shift
				;;
			--profile=*)
				_arg_profile="${_key##--profile=}"
				;;
			-p*)
				_arg_profile="${_key##-p}"
				;;
			-v|--version)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
			    _arg_version="$2"
				shift
				;;
			--version=*)
				_arg_version="${_key##--version=}"
				;;
			-v*)
				_arg_version="${_key##-v}"
				;;
			-h|--help)
				print_help
				exit 0
				;;
			-h*)
				print_help
				exit 0
				;;
			*)
				_last_positional="$1"
				_positionals+=("$_last_positional")
				_positionals_count=$((_positionals_count + 1))
				;;
		esac
		shift
	done
}

handle_passed_args_count()
{
	local _required_args_string="'operation'"
	test "${_positionals_count}" -ge 1 || _PRINT_HELP=yes die "FATAL ERROR: Not enough positional arguments - we require exactly 1 (namely: $_required_args_string), but got only ${_positionals_count}." 1
	test "${_positionals_count}" -le 1 || _PRINT_HELP=yes die "FATAL ERROR: There were spurious positional arguments --- we expect exactly 1 (namely: $_required_args_string), but got ${_positionals_count} (the last one was: '${_last_positional}')." 1
}

assign_positional_args()
{
	local _positional_name _shift_for=$1
	_positional_names="_arg_operation "

	shift "$_shift_for"
	for _positional_name in ${_positional_names}
	do
		test $# -gt 0 || break
		eval "$_positional_name=\${1}" || die "Error during argument parsing, possibly an Argbash bug." 1
		shift
	done
}

parse_commandline "$@"
handle_passed_args_count
assign_positional_args 1 "${_positionals[@]}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "Couldn't determine the script's running directory, which probably matters, bailing out" 2

# End of arg parsing


#****** UPGRADE CONFIG AND REAPPLY PLACEHOLDERS ******#
upgrade_config(){

	UPGRADER_DIR="$DOCKER_ROOT/am-config-upgrader"
	AM_DIR="$DOCKER_ROOT/am"
	printf "\nReplacing missing placeholders using AM config upgrader...\n\n"
	printf "Skaffold is used to run the AM upgrader job. Ensure your default-repo is set.\n\n"
	sleep 3

	rm -fr "$UPGRADER_DIR/config"

	cp -R "$DOCKER_ROOT/am/config"  "$UPGRADER_DIR/"
	rm -fr "$AM_DIR/config"

	echo "Removing any existing config upgrader jobs..."
	kubectl delete job am-config-upgrader || true

	# Deploy AM config upgrader job
	echo "Deploying AM config upgrader job..."
	exp=$(skaffold run -p config-upgrader)

	# Check to see if AM config upgrader pod is running
	echo "Waiting for AM config upgrader to come up."
	while ! [[ "$(kubectl get pod -l app=am-config-upgrader --field-selector=status.phase=Running)" ]];
	do
			sleep 5;
	done
	printf "AM config upgrader is responding..\n\n"

	pod=`kubectl get pod -l app=am-config-upgrader -o jsonpath='{.items[0].metadata.name}'`

	rm -fr "$UPGRADER_DIR/config"

	kubectl exec $pod -- /home/forgerock/tar-config.sh
	kubectl cp $pod:/am-config/config/placeholdered-config.tar "$UPGRADER_DIR/placeholdered-config.tar"

	tar -xvf $UPGRADER_DIR/placeholdered-config.tar -C $UPGRADER_DIR

	cp -R "$UPGRADER_DIR/config"  "$AM_DIR"
	rm -fr "$UPGRADER_DIR/config"
	rm "$UPGRADER_DIR/placeholdered-config.tar"

	# Shut down config upgrader job
	printf "Shutting down config upgrader job...\n"

	del=$(skaffold delete -p config-upgrader)
}

# clear the product configs $1 from the docker directory.
clean_config()
{
    $script_dir/platform-config --clean
}

patch_container() {
   cd $(dirname "${BASH_SOURCE[0]}")
   BASE_PATH=..
   TARGET_PATH=${BASE_PATH}/config/7.0/$1
   OVERLAY_PATH=${BASE_PATH}/config/$2
   if [[ ! -d "${OVERLAY_PATH}" ]];
   then
       echo "${OVERLAY_PATH} profile found"
       exit 0
   fi

   if ! docker pull -q gcr.io/forgeops-public/patcher:7.1-dev > /dev/null 2>&1;
   then
       echo "couldn't pull patch config tools, attempting to build"
       if ! docker build -q -t gcr.io/forgeops-public/patcher:7.1-dev ${BASE_PATH}/docker/cli-tools/patcher;
       then
           echo "cloudn't build or pull patch config tools, aborting"
           exit 1
       fi
   fi

   # build baseline from target
   OUTPUT_PATH=${BASE_PATH}/docker/7.0
   cp -R $TARGET_PATH/* "$OUTPUT_PATH/"
   shopt -s globstar
   # overwrite baseline with patches
   for patch in $OVERLAY_PATH/**/*.json;
   do
       patch_filename=$(basename ${patch})
       output_base_path=$(dirname ${patch/$OVERLAY_PATH/$OUTPUT_PATH})
       mkdir -p $output_base_path
       # a file with a patch has a patch applied
       if [[ "$patch_filename" == *"patch.json" ]];
       then
           # this is the file we want to run a patch against
           target_name=${patch_filename/.patch/}
           # dirname of targetted file
           target_base_path=$(dirname ${patch/${OVERLAY_PATH}/$TARGET_PATH})
           # fully qualified path to target
           target_path="${target_base_path}/${target_name}"
           # fully qualified path to output
           output="${output_base_path}/${target_name}"
           cat $target_path <(echo "=====") $patch | docker run -i gcr.io/forgeops-public/patcher:7.1-dev > $output
           continue
       fi
       # copy files if they don't have patch in the name
       cp "${patch}" "${output_base_path}/${patch_filename}"
   done
   exit 0
}

# Copy the product config $1 to the docker directory.
init_config()
{
    ${script_dir}/platform-config --clean --force --profile-name "${_arg_profile}"
}

# Show the differences between the source configuration and the current Docker configuration
# Ignore dot files, shell scripts and the Dockerfile
# $1 - the product to diff
diff_config()
{
	for p in "${COMPONENTS[@]}"; do
		echo "diff  -u --recursive ${PROFILE_ROOT}/$p $DOCKER_ROOT/$p"
		diff -u --recursive -x ".*" -x "Dockerfile" -x "*.sh" "${PROFILE_ROOT}/$p" "$DOCKER_ROOT/$p" || true
	done
}

# Export out of the running instance to the docker folder
export_config(){
	for p in "${COMPONENTS[@]}"; do
	   # We dont support export for all products just yet - so need to case them
	   case $p in
		idm)
			printf "\nExporting IDM configuration...\n\n"
			rm -fr  "$DOCKER_ROOT/idm/conf"
			kubectl cp idm-0:/opt/openidm/conf "$DOCKER_ROOT/idm/conf"
			;;
		amster)
			rm -fr "$DOCKER_ROOT/amster/config"
			mkdir -p "$DOCKER_ROOT/amster/config"
			"$script_dir/amster" export "$DOCKER_ROOT/amster/config"
			echo "Removing any existing Amster jobs..."
			kubectl delete job amster || true

			# Deploy Amster job
			echo "Deploying Amster job..."
			exp=$(skaffold run -p amster-export)

			# Check to see if Amster pod is running
			echo "Waiting for Amster pod to come up."
			while ! [[ "$(kubectl get pod -l app=amster --field-selector=status.phase=Running)" ]];
			do
					sleep 5;
			done
			printf "Amster job is responding..\n\n"

			pod=`kubectl get pod -l app=amster -o jsonpath='{.items[0].metadata.name}'`

			# Export OAuth2Clients and IG Agents
			echo "Executing Amster export within the amster pod"
			kubectl exec $pod -it /opt/amster/export.sh

			# Copy files locally
			echo "Copying the export to the ./tmp directory"
			kubectl cp $pod:/var/tmp/amster/realms/ "$DOCKER_ROOT/amster/config"

			printf "Dynamic config exported\n\n"

			# Shut down Amster job
			printf "Shutting down Amster job...\n"

			del=$(skaffold delete -p amster-export)
			;;
		am)
			# Export AM configuration
			printf "\nExporting AM configuration..\n\n"

			pod=$(kubectl get pod -l app=am -o jsonpath='{.items[0].metadata.name}')

			kubectl exec $pod -- /home/forgerock/export.sh - | (cd "$DOCKER_ROOT"/am; tar xvf - )

			printf "\nAny changed configuration files have been exported into ${DOCKER_ROOT}/am/config."
			printf "\nCheck any changed files before saving back to the config folder to ensure correct formatting/functionality."

			# Upgrade config and reapply placeholders
			upgrade_config
			;;
		*)
			echo "Export not supported for $p"
		esac
	done
}

# Export config from the fr-config git-server to local environment
# AM configs are processed using the config-upgrader before exporting
export_config_dev(){

	UPGRADER_DIR="$DOCKER_ROOT/am-config-upgrader"
    echo "Exporting configs"
	echo "Replacing missing placeholders using AM config upgrader"
	printf "Skaffold is used to run the AM upgrader job. Ensure your default-repo is set.\n\n"
	sleep 3

	rm -fr "$UPGRADER_DIR/fr-config"
	mkdir -p "$UPGRADER_DIR/fr-config"
    mkdir -p "$UPGRADER_DIR/config"
    touch "$UPGRADER_DIR/config/placeholder"

	echo "Removing any existing config upgrader jobs..."
	kubectl delete job fr-config-exporter --ignore-not-found --wait=true --timeout=30s

	# Deploy AM config upgrader job
	echo "Deploying AM config upgrader job..."
	exp=$(skaffold run -p fr-config-exporter)

	# Check to see if AM config upgrader pod is running
	printf "Waiting for the fr-config-exporter job to initialize: "
    while ! [[ "$(kubectl get pod -l app.kubernetes.io/name=fr-config-exporter --field-selector=status.phase=Running 2> /dev/null)" ]];
	do
        printf "."
        sleep 5;
	done
    echo "done"
	pod=$(kubectl get pod -l app.kubernetes.io/name=fr-config-exporter -o jsonpath='{.items[0].metadata.name}')
    echo "Targeting $pod"
	kubectl exec $pod -c wait-for-copy -- /scripts/tar-config.sh
    echo "Copying configs from $pod into local environment"
	kubectl cp $pod:/git/placeholdered-config.tar.gz "$UPGRADER_DIR/placeholdered-config.tar.gz"
	tar -xzf $UPGRADER_DIR/placeholdered-config.tar.gz -C $UPGRADER_DIR

    # Copy exported configs to docker folder
    for p in "${COMPONENTS[@]}"; do
        # We dont support export for all products just yet - so need to case them
        case $p in
		am)
            if [[ -d  "$UPGRADER_DIR/fr-config/am" ]];
            then
                DOCKER_EXPORT_DIR="$DOCKER_ROOT/am"
                rm -fr "$DOCKER_EXPORT_DIR/config"
                cp -R "$UPGRADER_DIR/fr-config/am/config"  "$DOCKER_EXPORT_DIR"
            fi
			;;
        idm)
            if [[ -d  "$UPGRADER_DIR/fr-config/idm" ]];
            then
                DOCKER_EXPORT_DIR="$DOCKER_ROOT/idm"
                rm -fr "$DOCKER_EXPORT_DIR/conf"
                cp -R "$UPGRADER_DIR/fr-config/idm/conf" "$DOCKER_EXPORT_DIR"
            fi
            ;;
		*)
        	echo "Git export not supported for $p"
            ;;
		esac
	done

    echo "Deleting temporary files"
	rm -fr "$UPGRADER_DIR/fr-config"
    rm "$UPGRADER_DIR/placeholdered-config.tar.gz"

	# Shut down config upgrader job
	echo "Shutting down config upgrader job..."
	del=$(skaffold delete -p fr-config-exporter)
}

# Save the configuration in the docker folder back to the git source
save_config()
{
	# Create the profile dir if it does not exist
	[[ -d "$PROFILE_ROOT" ]] || mkdir -p "$PROFILE_ROOT"

	for p in "${COMPONENTS[@]}"; do
		# We dont support export for all products just yet - so need to case them
		case $p in
		idm)
			printf "\nSaving IDM configuration..\n\n"
			# clean existing files
			rm -fr  "$PROFILE_ROOT/idm/conf"
			mkdir -p "$PROFILE_ROOT/idm/conf"
			cp -R "$DOCKER_ROOT/idm/conf"  "$PROFILE_ROOT/idm"
			;;
		amster)
			printf "\nSaving Amster configuration..\n\n"
			#****** REMOVE EXISTING FILES ******#
			rm -fr "$PROFILE_ROOT/amster/config"
			mkdir -p "$PROFILE_ROOT/amster/config"

			#****** FIX CONFIG RULES ******#

			# Fix FQDN and amsterVersion fields with placeholders. Remove encrypted password field.
			fqdn=$(kubectl get configmap platform-config -o yaml |grep AM_SERVER_FQDN | head -1 | awk '{print $2}')

			printf "\n*** APPLYING FIXES ***\n"

			echo "Adding back amsterVersion placeholder ..."
			echo "Adding back FQDN placeholder ..."
			echo "Removing 'userpassword-encrypted' fields ..."
			find "$DOCKER_ROOT/amster/config" -name "*.json" \
					\( -exec sed -i '' "s/${fqdn}/\&{fqdn}/g" {} \; -o -exec true \; \) \
					\( -exec sed -i '' 's/"amsterVersion" : ".*"/"amsterVersion" : "\&{version}"/g' {} \; -o -exec true \; \) \
					-exec sed -i '' '/userpassword-encrypted/d' {} \; \

			# Fix passwords in OAuth2Clients with placeholders or default values.
			CLIENT_ROOT="$DOCKER_ROOT/amster/config/root/OAuth2Clients"
			IGAGENT_ROOT="$DOCKER_ROOT/amster/config/root/IdentityGatewayAgents"

			echo "Add back password placeholder with defaults"
			sed -i '' 's/\"userpassword\" : null/\"userpassword\" : \"\&{idm.provisioning.client.secret|openidm}\"/g' ${CLIENT_ROOT}/idm-provisioning.json
			sed -i '' 's/\"userpassword\" : null/\"userpassword\" : \"\&{idm.rs.client.secret|password}\"/g' ${CLIENT_ROOT}/idm-resource-server.json
			sed -i '' 's/\"userpassword\" : null/\"userpassword\" : \"\&{ig.rs.client.secret|password}\"/g' ${CLIENT_ROOT}/resource-server.json
			sed -i '' 's/\"userpassword\" : null/\"userpassword\" : \"\&{pit.client.secret|password}\"/g' ${CLIENT_ROOT}/oauth2.json
			sed -i '' 's/\"userpassword\" : null/\"userpassword\" : \"\&{ig.agent.password|password}\"/g' ${IGAGENT_ROOT}/ig-agent.json

			#****** COPY FIXED FILES ******#
			cp -R "$DOCKER_ROOT/amster/config"  "$PROFILE_ROOT/amster"

			printf "\n*** The above fixes have been made to the Amster files. If you have exported new files that should contain commons placeholders or passwords, please update the rules in this script.***\n\n"
			;;

		*)
			printf "\nSaving AM configuration..\n\n"
			#****** REMOVE EXISTING FILES ******#
			rm -fr "$PROFILE_ROOT/am/config"
			mkdir -p "$PROFILE_ROOT/am/config"

			#****** COPY FIXED FILES ******#
			cp -R "$DOCKER_ROOT/am/config"  "$PROFILE_ROOT/am"
		esac
	done
}

add_profile ()
{

    # if the version isn't 7.0 use it as the branch for platform-images
    [[ $_arg_version != "7.0" ]] && branch_name=$_arg_version
    if ! ${script_dir}/platform-config --profile fidc --branch-name "${branch_name}"
    then
        echo "Failed to clone addon profile"
        exit 1;
    fi
    # add amster
    cp -r "${script_dir}/../config/7.0/cdk/amster" "$DOCKER_ROOT"

}

# chdir to the script root/..
cd "$script_dir/.."
PROFILE_ROOT="config/$_arg_version/$_arg_profile"
DOCKER_ROOT="docker/$_arg_version"


if [ "$_arg_component" == "all" ]; then
	COMPONENTS=(idm ig amster am)
else
	COMPONENTS=( "$_arg_component" )
fi

case "$_arg_operation" in

init-addon-profile)
	clean_config idm ig amster am
    add_profile
    ;;

init)
	clean_config "${COMPONENTS[@]}"
	init_config "${COMPONENTS[@]}"
	;;
add)
	# Same as init - but do not delete existing files.
	init_config "${COMPONENTS[@]}"
	;;
clean)
	clean_config "${COMPONENTS[@]}"
	;;
diff)
	diff_config
	;;
export)
	export_config
	;;
import)
	$script_dir/amster import $PROFILE_ROOT/amster
	;;
save)
	save_config
	;;
sync)
	export_config
	save_config
	;;
upgrade)
	upgrade_config
	;;
export-dev)
	export_config_dev
	;;
restore)
	git restore "$PROFILE_ROOT"
	;;
*)
	echo "Unknown command $_arg_operation"
esac
