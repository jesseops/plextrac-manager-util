# Instance & Utility Update Management
#
# Usage: plextrac update

# subcommand function, this is the entrypoint eg `plextrac update`
function mod_update() {
  title "Updating PlexTrac Instance"
  # I'm comparing an int :shrug:
  # shellcheck disable=SC2086
  if [ ${SKIP_SELF_UPGRADE:-0} -eq 0 ]; then
    info "Checking for updates to the PlexTrac Management Utility"
    if selfupdate_checkForNewRelease; then
      event__log_activity "update:upgrade-utility" "${releaseInfo}"
      selfupdate_doUpgrade
      die "Failed to upgrade PlexTrac Management Util! Please reach out to support if problem persists"
      exit 1 # just in case, previous line should already exit
    fi
  else
    info "Skipping self upgrade"
  fi

  info "Updating PlexTrac instance to latest release..."
  mod_configure
  title "Pulling latest container images"
  pull_docker_images
  if [ "$IMAGE_CHANGED" == true ]
    then
      title "Executing Rolling Deployment"
      mod_rollout
  fi

  # Sometimes containers won't start correctly at first, but will upon a retry
  maxRetries=2
  for i in $( seq 1 $maxRetries ); do
    mod_start || sleep 5 # Wait before going on to health checks, they should handle triggering retries if mod_start errors

    unhealthy_services=$(compose_client ps -a --format json | \
      jq -r '. | select(.Health == "unhealthy" or (.State != "running" and .ExitCode != 0) or .State == "created" ) | .Service' | \
      xargs -r printf "%s;")

    if [[ "${unhealthy_services}" == "" ]]; then break; fi

    info "Detected unhealthy services: ${unhealthy_services}"

    if [[ $i -ge $maxRetries ]]; then
      error "One or more containers are in a failed state, please contact support!"
      exit 1
    fi

    info "An error occurred with one or more containers, attempting to start again"
    sleep 5

  done

  mod_check

  title "Update complete"
}

function _selfupdate_refreshReleaseInfo() {
  releaseApiUrl='https://api.github.com/repos/PlexTrac/plextrac-manager-util/releases'
  targetRelease="${PLEXTRAC_UTILITY_VERSION:-latest}"
  if [ "${targetRelease}" == "latest" ]; then
    releaseApiUrl="${releaseApiUrl}/${targetRelease}"
  else
    releaseApiUrl="${releaseApiUrl}/tags/${targetRelease}"
  fi

  if test -z ${releaseInfo+x}; then
    _check_base_required_packages
    export releaseInfo="`wget -O - -q $releaseApiUrl`"
    info "$releaseApiUrl"
    if [ $? -gt 0 ] || [ "$releaseInfo" == "" ]; then die "Failed to get updated release from GitHub"; fi
    debug "`jq . <<< "$releaseInfo"`"
  fi
}

function selfupdate_checkForNewRelease() {
  #if test -z ${DIST+x}; then
  #  log "Running in local mode, skipping release check"
  #  return 1
  #fi
  _selfupdate_refreshReleaseInfo
  releaseTag="`jq '.tag_name' -r <<<"$releaseInfo"`"
  releaseVersion="`_parseVersion "$releaseTag"`"
  if [ "$releaseVersion" == "" ]; then die "Unable to parse release version, cannot continue"; fi
  localVersion="`_parseVersion "$VERSION"`"
  debug "Current Version: $localVersion"
  debug "Latest Version: $releaseVersion"
  if [ "$localVersion" == "$releaseVersion" ]; then
    info "$localVersion is already up to date"
    return 1
  fi
  info "Updating from $localVersion to $releaseVersion"

  return 0
}

function _parseVersion() {
  rawVersion=$1
  sed -E 's/^v?(.*)$/\1/' <<< $rawVersion
}

function info_getReleaseDetails() {
  changeLog=$(jq '.body' <<<$releaseInfo)
  debug "$changeLog"
}

function selfupdate_doUpgrade() {
  info "Starting Self Update"
  releaseVersion=$(jq '.tag_name' -r <<<$releaseInfo)
  scriptAsset="`jq '.assets[] | select(.name=="plextrac") | .' <<<"$releaseInfo"`"
  scriptAssetSHA256SUM="`jq '.assets[] | select(.name=="sha256sum-plextrac.txt") | .' <<<"$releaseInfo"`"
  if [ "$scriptAsset" == "" ]; then die "Failed to find release asset for ${releaseVersion}"; fi

  debug "Downloading updated script from $scriptAsset"
  tempDir=`mktemp -d -t plextrac-$releaseVersion-XXX`
  debug "Tempdir: $tempDir"
  target="${PLEXTRAC_HOME}/.local/bin/plextrac"
  
  debug "`wget $releaseApiUrl -O $tempDir/$(jq -r '.name, " ", .browser_download_url' <<<$scriptAsset) 2>&1 || error "Release download failed"`"
  debug "`wget -O $tempDir/$(jq -r '.name, " ", .browser_download_url' <<<$scriptAsset) 2>&1 || error "Release download failed"`"
  debug "`wget -O $tempDir/$(jq -r '.name, " ", .browser_download_url' <<<$scriptAssetSHA256SUM) 2>&1 || error "Checksum download failed"`"
  checksumoutput=`pushd $tempDir >/dev/null && sha256sum -c sha256sum-plextrac.txt 2>&1` || die "checksum failed: $checksumoutput"
  debug "$checksumoutput"
  tempScript="$tempDir/plextrac"
  chmod a+x $tempScript && debug "`$tempScript help 2>&1 | grep -i "plextrac management utility" 2>&1`" || die "Invalid script $tempScript"

  info "Successfully downloaded & tested update"
  log "Backing up previous release & installing $releaseVersion"
  debug "Moving $tempScript to $target"
  debug "`cp -vb --suffix=.bak $tempScript "$target" 2>&1`"
  debug `chmod -v a-x "${target}.bak" || true`
  debug `chmod -v a+x $target`
  info "Upgrade complete"

  debug "Initially called '$ProgName' w/ args '$_INITIAL_CMD_ARGS'" 
  debug "Script Backup: `sha256sum ${target}.bak`"
  debug "Script Update: `sha256sum $target`"

  eval "SKIP_SELF_UPGRADE=1 $ProgName $_INITIAL_CMD_ARGS"
  exit $?
}
