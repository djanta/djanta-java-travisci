#!/usr/bin/env bash
#
# Copyright 2019-2020 DJANTA, LLC (https://www.djanta.io)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed toMap in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

argv0=$(echo "$0" | sed -e 's,\\,/,g')
basedir=$(dirname "$(readlink "$0" || echo "$argv0")")

case "$(uname -s)" in
  Linux) basedir=$(dirname "$(readlink -f "$0" || echo "$argv0")");;
  *CYGWIN*) basedir=`cygpath -w "$basedir"`;;
esac

# shellcheck disable=SC1090
source "${basedir}"/common.sh

if [[ "$#" -eq 0 ]] &&  [[ ! -f ".version" ]]; then
  error_exit "Insuffisant command argument"
fi

# Load the pom version
#[ -f "pom.xml" ] && version=`./mvnw -o help:evaluate -N -Dexpression=project.version | sed -n '/^[0-9]/p'` || \
#    version="0.0.1-SNAPSHOT" # Set the default pom version to "0.0.1-SNAPSHOT"

#echo "[*] Version: ${version}"

# shellcheck disable=SC2006
increment() {
  local version=$1
  result=`echo "${version}" | awk -F. -v OFS=. 'NF==1{print ++$NF}; NF>1{if(length($NF+1)>length($NF))$(NF-1)++; $NF=sprintf("%0*d", length($NF), ($NF+1)%(10^length($NF))); print}'`
  echo "${result}-SNAPSHOT"
}

#safe_checkout() {
#  # We need to be on a branch for release:perform to be able to create commits, and we want that branch to be master.
#  # But we also want to make sure that we build and release exactly the tagged version, so we verify that the remote
#  # master is where our tag is.
#  branch="${1:-master}"
#  git checkout -B "${branch}"
#  git fetch origin "${branch}":origin/"${branch}"
#  commit_local="$(git show --pretty='format:%H' "${branch}")"
#  commit_remote="$(git show --pretty='format:%H' origin/"${branch}")"
#  if [[ "$commit_local" != "$commit_remote" ]]; then
#    echo "${branch} on remote 'origin' has commits since the version under release, aborting"
#    exit 1
#  fi
#}

update_release() {
  if [[ -f .version ]]; then
    colored --blue "Updating next release version in (.version) file ..."
    sed -i "s/NEXT_RELEASE=${1}/NEXT_RELEASE=${2}/g" .version
  fi
}

###
# Deploy the given profiles
# shellcheck disable=SC2116
##
deploy() {
  colored --yellow "[Deploy] - About to deploy in branch: $(git_current_branch)"

  DEPLOY=""
  IFS=';' # hyphen (;) is set as delimiter
  read -ra PROFILES <<< "${MVN_PROFILES:-}" # str is read into an array as tokens separated by IFS
  for profile in "${PROFILES[@]}"; do # access each element of array
    DEPLOY=${DEPLOY}"./mvnw ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_SETTINGS:-} -P${profile} ${MVN_VARG:-} -DskipTests=true clean deploy && "
  done
  IFS=' ' # reset to default value after usage
  DEPLOY=${DEPLOY}"echo 'Done!'"

  colored --blue "[Deploy] - ${DEPLOY}"
  eval $DEPLOY
}

# shellcheck disable=SC2046
switch_to() {
  argv inreleasebranch '--release-branch' "${@:1:$#}"

  [[ ! -z "$inreleasebranch" ]] && releasebranch="${inreleasebranch}" || releasebranch="${RELEASE_BRANCH:-release}"

  colored --yellow "[switch] - About to rebase from branch: ${releasebranch}, isMaster? : $(is_master_branch)"

  git fetch --prune --all # Fetch & prune all
  git pull origin $(git_current_branch) --allow-unrelated-histories # Pull from the current origin branch

  # Merge the current tagging branch into the master branch
  if ! is_master_branch; then
    colored --blue "[switch] - Checking out branch master"

    #safe_checkout "master"
    git checkout "master"
    git pull origin --allow-unrelated-histories # Pull from the remote origin
    if [[ -z $(git status --porcelain) ]];
    then
      colored --yellow "[switch] - No changes detected, all good"
    else
      colored --green "[switch] - Merging from: ${releasebranch} into: $(git_current_branch)"
      git merge "${releasebranch}"
    fi
  else
    colored --yellow "[switch] - The release could not be performed in branch: $(git_current_branch)"
  fi
}

# shellcheck disable=SC2154
__tag__() {
  colored --yellow "[tag] - About to tag from branch: $(git_current_branch)"

  argv inseparator '--separator' "${@:1:$#}"
  argv inarg '--arg' "${@:1:$#}"
  argv intag '--tag' "${@:1:$#}"
  argv insnapshot '--snapshot' "${@:1:$#}"
  argv inlabel '--tag-prefix' "${@:1:$#}"
  argv inprofile '--profile' "${@:1:$#}"

#  colored --green "[tag] - In label=${inlabel}"

  [[ ! -z "$intag" ]] && tag="${intag}" || tag=''
  #[[ ! -z "$inlabel" ]] && fullversion="${inlabel}-${tag}" || fullversion=''
  [[ ! -z "$inlabel" ]] && fullversion="${inlabel}${inseparator:-}${tag}" || fullversion=''
  [[ ! -z "$fullversion" ]] && label="-Dtag=${fullversion}" || label=''
  [[ ! -z "$insnapshot" ]] && snapshot="${insnapshot}" || snapshot="$(increment "${tag}")"

  ## Version argument declaration ...
  [[ ! -z "$tag" ]] && tag_argv="-DnewVersion=${tag}" || tag_argv='-DremoveSnapshot'
  [[ ! -z "$snapshot" ]] && snapshot_argv="-DnewVersion=${snapshot}" #|| snapshot_argv="-DnewVersion=$(increment "${tag}")"

  [[ ! -z $(is_tag_exists "${fullversion}") ]] && colored --green "[Release] tag: ${fullversion}, already exist" \
    && error_exit "Following tag: ${fullversion}, has already existed."

  # Update the versions, removing the snapshots, then create a new tag for the release, will start release process.
  ./mvnw ${MVN_SETTINGS:-} ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_VARG:-} versions:set scm:checkin "${tag_argv}" \
    -DgenerateBackupPoms=false -Dmessage="prepare release ${tag}" -DpushChanges=false

  # Now tag the relased version
  ./mvnw ${MVN_SETTINGS:-} ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_VARG:-} "${label}" \
    -Dmvn.tag.prefix="${inlabel}${inseparator:-}" scm:tag

  ## No Sync
  #./mvnw ${MVN_SETTINGS:-} ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_VARG:-} \
  #   -nsu -N io.zipkin.centralsync-maven-plugin:centralsync-maven-plugin:sync

  #Temporally fix to manually deploy (Deploy the new release tag)
  colored --green "[Release] Deploying tagged branch version: (${tag}) into the remote registry."
  deploy #"${inprofile}" "${tag}" # Deploy after version tag is created

  ## Now merge the working tag branch into master & then push the master
  switch_to --release-branch="${RELEASE_BRANCH}" --target-branch="master"

  # Update the versions to the next snapshot
  echo "Updating next development iteration (${snapshot})"
  ./mvnw ${MVN_SETTINGS:-} ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_VARG:-} versions:set scm:checkin "${snapshot_argv}" \
    -DgenerateBackupPoms=false -Dmessage="[CI/CD] Updating next development iteration :: (${snapshot})"

  # Temporally fix to manually deploy (Deploy the new snapshot)
  colored --green "[Release] Pushing snapshot version: (${snapshot}) into branch: $(git_current_branch)"
  git push origin "$(git_current_branch)"
#  deploy #"${inprofile}" "${tag}" # Deploy after snapshot version is created
}

##
# Incremental versioning
# shellcheck disable=SC2006
# shellcheck disable=SC2154
# shellcheck disable=SC2236
##
api() {
  [[ -f "$(pwd)/pom.xml" ]] && colored --green "[api] - Maven (POM) file exists on path: $(pwd)" \
    || colored --red "[api] - Maven (POM) file not found in path: $(pwd)"

  colored --yellow "[api] - arguments: ${MVN_SETTINGS:-} ${MVN_BASHMODE:-} ${MVN_DEBUG:-} ${MVN_VARG:-}"

  if [[ ! -z "$NEXT_RELEASE" ]]; then
    tag="$NEXT_RELEASE"
    export PREV_RELEASE="$NEXT_RELEASE"
  else
    [[ -f "$(pwd)/.snapshot" ]] && colored --yellow "[api] - Removing : $(pwd)/.snapshot" && rm -v "$(pwd)/.snapshot" \
      && mvn -B -q -U clean validate -N help:evaluate ${MVN_SETTINGS:-} -DexportVersion=true \
      && colored --cyan "[api] - POM Snapshot: $(cat $(pwd)/.snapshot)" \
      || mvn -B -q -U clean validate -N help:evaluate ${MVN_SETTINGS:-} -DexportVersion=true

    # extract the release version from the pom file
    [[ -f "$(pwd)/.snapshot" ]] && version=$(cat $(pwd)/.snapshot) && version=$(printf '%s\n' "${version//"-SNAPSHOT"/}") \
      || version=`./mvnw -B help:evaluate -N -f "$(pwd)/pom.xml" -Dexpression=project.version -q -DforceStdout`

    ## Make sure we remove the snapshot file ...
    rm -fv "$(pwd)/.snapshot"

    #version=`./mvnw -o -B help:evaluate -f "$(pwd)/pom.xml" -N -Dexpression=project.version | sed -n '/^[0-9]/p'`
    #version=`mvn -o -B help:evaluate -f "$(pwd)/pom.xml" -Dexpression=project.version -q -DforceStdout | grep -e '^[^\[]'`
    tag=`echo "${version}" | cut -d'-' -f 1`
  fi

  argv inseparator '--separator' "${@:1:$#}"
  argv inlabel '--label' "${@:1:$#}"
  argv inpatch '--patch' "${@:1:$#}"
  argv insnapshot '--next-snapshot' "${@:1:$#}"
  argv invarg '--varg' "${@:1:$#}"
  argv inprofile '--profile' "${@:1:$#}"

  [[ ! -z "$insnapshot" ]] && snapshot="$insnapshot" || snapshot=$(increment "${tag}")

  ## Get starting release process ...
  __tag__ --tag="${tag}" --tag-prefix="${inlabel:-"v"}" --snapshot="${snapshot}" --arg="${invarg:-}" \
    --separator="${inseparator}"
}

#Date based versioning
# shellcheck disable=SC2154
ts() {
  colored --blue "[timestamp] Building version base release"

  argv fulldate '--full-date' "${@:1:$#}"
  argv informat '--format' "${@:1:$#}"

  argv inday '--day' "${@:1:$#}"
  argv inmonth '--month' "${@:1:$#}"
  argv inyear '--year' "${@:1:$#}"

  argv inlabel '--label' "${@:1:$#}"
  argv seperator '--separator' "${@:1:$#}"
  argv inpatch '--patch' "${@:1:$#}"
  argv inprofile '--profile' "${@:1:$#}"

  argv invarg '--varg' "${@:1:$#}"
  exists is_incremental '--continue-snapshot' "${@:1:$#}"
  argv innextsnapshot '--next-snapshot' "${@:1:$#}"

  [[ ! -z "$NEXT_RELEASE" ]] && nextrelease="$NEXT_RELEASE" || nextrelease=$(date +'%y.%m.%d')
  [[ ! -z "$informat" ]] && format="$informat" || format='%y.%m.%d'
  [[ ! -z "$fulldate" ]] && now=$(date -j -f "${format}" "$fulldate" +"${format}") || now="$nextrelease"
  [[ ! -z "$inday" ]] && d="$inday" || d="$(date -j -f "${format}" "$now" '+%d')"
  [[ ! -z "$inmonth" ]] && m="$inmonth" || m="$(date -j -f "${format}" "$now" '+%m')"
  [[ ! -z "$inyear" ]] && y="$inyear" || y="$(date -j -f "${format}" "$now" '+%y')"

  local sep="${seperator:-.}"
  local ver="${y}${sep}${m}${sep}${d}"

  [[ ! -z "$inpatch" ]] && tag="${ver}-${inpatch}" || tag="$ver"

  # shellcheck disable=SC2154
  [[ ! -z "${innextsnapshot}" ]] && snapshot="${innextsnapshot}" #|| snapshot="${y}${sep}${m}${sep}$(($(date '+%d') + 1))-SNAPSHOT"
  __tag__ --tag="${tag}" --tag-prefix="${inlabel:-}" --snapshot="${snapshot:-}" --arg="${invarg:-}"
}

###
# Generating gh_pages
####
javadoc() {
  colored --blue "[Javadoc] Generating gh_pages for documentation purposes."

  javadoc_to_gh_pages
}

help_message () {
  #$(usage "${@:1:$#}")
  cat <<-EOF
  $PROGNAME
  This script will be use to tag your maven project with two type versioning style.
  #./release timestamp [--format=.., --full-date=..[[--year.., --month=.., --day=..]], --patch]

  Global:

    --label The given expect label used to tag the released version (release|tag|rc), etc...
    --next-snapshot Define this option (no matter the value) to indicate the ongoing snapshot version
    --patch Use this option to define the current patching version stage
    --setting-file This option is globaly used to define the target maven settings file
    --bash-mode This option can globaly use to define maven internal (-B) option
    --debug global option used activate maven (X) option
    --profile this option define your maven profile. ex: sonatype,other. If you wish to run your profile separaly, please use a comma (;) separator ex: sonatype,other;!sonatype,github

  Options:

  -h, --help [(timestamp|ts) | (increment|api) ] Display this help message within the given command and exit.
  --timestamp [timestamp | -- ts | ts]: Release the current project based on timestamp format (e.g: $(date +'%y.%m.%d'))
  --increment [increment | --api | api]: Release the current project, by continueing the current version.

  $(usage "${1}")
EOF
  return
}

usage() {
  for i in "${@}"; do
    case ${i} in
      ts|timestamp)
cat <<-EOF
Timestamp base version release:

  $PROGNAME ${i} [--format=.., --full-date=..[[--year.., --month=.., --day=..]], --patch]
  --format Define the given date format. Otherwise, the default value is set to: %y.%m.%d
  --full-date Define the manual or initial date value. The default value will be set to: $(date +'%y.%m.%d')
  --day Manually override the given version date
  --month Manually override the given version year

EOF
        ;;
      api|increment)
cat <<-EOF
//FIXME: NYI
EOF
     ;;
    esac
  done
}

if [[ $1 =~ ^((--)?((timestamp|ts)|(api|increment)|(javadoc|doc)|(help)))$ ]]; then
  XCMD="${1}"
  INDEX=2
else
  INDEX=1
  [[ ! -z "${RELEASE_STYLE}" ]] && XCMD="$RELEASE_STYLE" || XCMD='--help'
fi

# shellcheck disable=SC2154
if [[ "${XCMD}" != "--help" ]] && [[ "${XCMD}" != "-h" ]]; then
  exists inbashmodel '--bash-mode' "${@:$INDEX:$#}"
  exists indebug '--debug' "${@:$INDEX:$#}"

  argv insettingfile '--setting-file' "${@:$INDEX:$#}"
  argv inprofile '--profile' "${@:$INDEX:$#}"
  argv invarg '--varg' "${@:$INDEX:$#}"
  argv inrbranch '--release-branch' "${@:$INDEX:$#}"

  colored --blue "[Option] Maven settings: ${insettingfile}"
  colored --blue "[Option] Maven Profile: ${inprofile}"

  [[ "${inbashmodel}" ]] && export MVN_BASHMODE="-B" || colored --yellow "[Option] Maven bash mode Off"
  [[ "${indebug}" ]] && export MVN_DEBUG="-X" || colored --red "[Option] Maven debug Off"
  [[ -f "${insettingfile}" ]] && export MVN_SETTINGS="--settings ${insettingfile}" || colored --yellow "[Option] Maven settings Off"

  [[ -n "${inprofile}" ]] && export MVN_PROFILES="${inprofile}" || colored --yellow "[Option] Maven profiles Off"
  [[ -n "${invarg}" ]] && export MVN_VARG="${invarg}"

  # Load the project given .version file if any
  if [[ -f ".version" ]]; then
    colored --blue "Exporting .version file ..."
    export_properties .version
  fi

  colored --blue "Release branch: ${inrbranch}, Debug=${MVN_DEBUG}, Current Branch=$(git_current_branch)"
  colored --blue "Current version: ${inversion}, Current Branch=$(git_current_branch)"
  colored --blue "Settings: ${MVN_SETTINGS}, for Branch=$(git_current_branch)"

  rbranch="${RELEASE_BRANCH:-release}"
  [[ ! -z "${inrbranch}" ]] && export RELEASE_BRANCH="${inrbranch}" || export RELEASE_BRANCH="${rbranch}"

  # Check if we start the tag release from from the expected branch.
  [[ "${RELEASE_BRANCH}" != "$(git_current_branch)" ]] && error_exit "Expecting release should be: \"${RELEASE_BRANCH}\""
fi

case ${XCMD} in
  -h|--help)
    help_message "${@:$INDEX:$#}"
    graceful_exit ${?}
    ;;
  timestamp|ts|--timestamp|--ts)
    XCMD="ts"
    ;;
  api|--api|--increment|increment)
    XCMD="api"
    ;;
  javadoc|--javadoc)
    XCMD="javadoc"
    ;;
esac

if [[ -n "${XCMD}" ]]; then
  ${XCMD} "${@:$INDEX:$#}"
  graceful_exit ${?}
else
  graceful_exit
fi

# Trap signals
trap "signal_exit TERM" TERM HUP
trap "signal_exit INT" INT
