function tag_release {
   # Arguments:
   #   $1 - Path to top level consul source
   #   $2 - Version string to use for tagging the release
   #   $3 - Alternative GPG key id used for signing the release commit (optional)
   #
   # Returns:  
   #   0 - success
   #   * - error
   #
   # Notes:
   #   If the RELEASE_UNSIGNED environment variable is set then no gpg signing will occur
   
   if ! test -d "$1"
   then
      err "ERROR: '$1' is not a directory. tag_release must be called with the path to the top level source as the first argument'" 
      return 1
   fi
   
   if test -z "$2"
   then
      err "ERROR: tag_release must be called with a version number as the second argument" 
      return 1
   fi
   
   # determine whether the gpg key to use is being overridden
   local gpg_key=${HASHICORP_GPG_KEY}
   if test -n "$3"
   then
      gpg_key=$3
   fi
   
   pushd "$1" > /dev/null
   local ret=0
   
   # perform an usngined release if requested (mainly for testing locally)
   if is_set "$RELEASE_UNSIGNED"
   then
      (
         git commit --allow-empty -a -m "Release v${2}" &&
         git tag -a -m "Version ${2}" "v${2}" master
      )
      ret=$?
   # perform a signed release (official releases should do this)
   elif have_gpg_key ${gpg_key}
   then   
      (
         git commit --allow-empty -a --gpg-sign=${gpg_key} -m "Release v${2}" &&
         git tag -a -m "Version ${2}" -s -u ${gpg_key} "v${2}" master
      )
      ret=$?
   # unsigned release not requested and gpg key isn't useable
   else
      err "ERROR: GPG key ${gpg_key} is not in the local keychain - to continue set RELEASE_UNSIGNED=1 in the env"
      ret=1
   fi
   popd > /dev/null
   return $ret
}

function package_release {
   # Arguments:
   #   $1 - Path to the top level Consul source
   #   $2 - Version to use in the names of the zip files (optional)
   #
   # Returns:
   #   0 - success
   #   * - error
   
   if ! test -d "$1"
   then
      err "ERROR: '$1' is not a directory. package_release must be called with the path to the top level source as the first argument'" 
      return 1
   fi
   
   local vers="${2}"
   if test -z "${vers}"
   then
      vers=$(get_version $1 true)
      ret=$?
      if test "$ret" -ne 0
      then
         err "ERROR: failed to determine the version." 
         return $ret
      fi
   fi
   
   local sdir="$1"
   local ret=0

   rm -rf "${sdir}/pkg/dist" > /dev/null 2>&1 
   mkdir -p "${sdir}/pkg/dist" >/dev/null 2>&1 
   for platform in $(find "${sdir}/pkg/bin" -mindepth 1 -maxdepth 1 -type d)
   do
      local os_arch=$(basename $platform)
      local dest="${sdir}/pkg/dist/consul_${vers}_${os_arch}.zip"
      status "Compressing ${os_arch} directory into ${dest}"
      pushd "${platform}" > /dev/null
      zip "${sdir}/pkg/dist/consul_${vers}_${os_arch}.zip" ./*
      ret=$?
      popd > /dev/null
      
      if test "$ret" -ne 0
      then
         break
      fi
   done
   
   return $ret
}

function shasum_release {
   # Arguments:
   #   $1 - Path to directory containing the files to shasum
   #   $2 - File to output sha sums to
   #
   # Returns:
   #   0 - success
   #   * - failure
   
   if ! test -d "$1"
   then
      err "ERROR: '$1' is not a directory and shasum_release requires passing a directory as the first argument"
      return 1
   fi
   
   if test -z "$2"
   then
      err "ERROR: shasum_release requires a second argument to be the filename to output the shasums to but none was given"
      return 1 
   fi
   
   pushd $1 > /dev/null
   shasum -a256 * > "$2"
   ret=$?
   popd >/dev/null
   
   return $ret
}

function sign_release {
   # Arguments:
   #   $1 - File to sign
   #   $2 - Alternative GPG key to use for signing
   #
   # Returns:
   #   0 - success
   #   * - failure
   
   # determine whether the gpg key to use is being overridden
   local gpg_key=${HASHICORP_GPG_KEY}
   if test -n "$2"
   then
      gpg_key=$2
   fi
   
   gpg --default-key "${gpg_key}" --detach-sig "$1"
   return $?
}

function build_consul_release {
   build_consul "$1" "" "$2"  
}

function build_release {
   # Arguments:
   #   $1 - Path to the top level Consul source
   #   $2 - boolean whether to tag the release yet
   #   $3 - boolean whether to build the binaries
   #   $4 - boolean whether to generate the sha256 sums
   #   $5 - alternative gpg key to use for signing operations (optional)
   #
   # Returns:
   #   0 - success
   #   * - error
   
   if ! test -d "$1"
   then
      err "ERROR: '$1' is not a directory. build_release must be called with the path to the top level source as the first argument'" 
      return 1
   fi
   
   if test -z "$2" -o -z "$3" -o -z "$4"
   then
      err "ERROR: build_release requires 4 arguments to be specified: <path to consul source> <tag release bool?> <build binaries bool?> <shasum 256 bool?>" 
      return 1
   fi
   
   local sdir="$1"
   local do_tag="$2"
   local do_build="$3"
   local do_sha256="$4"
   local gpg_key="$5"
   
   local vers=$(get_version ${sdir} true)
   if test $? -ne 0
   then
      err "Please specify a version (couldn't find one based on build tags)." 
      return 1
   fi
   
   # Make sure we arent in dev mode
   unset CONSUL_DEV
   
   if is_set "${do_build}"
   then
      status_stage "==> Refreshing Docker Build Images"
      refresh_docker_images "${sdir}"
      if test $? -ne 0
      then
         err "ERROR: Failed to refresh docker images" 
         return 1
      fi
      
      status_stage "==> Building Legacy UI for version ${vers}"
      build_ui_legacy "${sdir}" "${UI_LEGACY_BUILD_TAG}"
      if test $? -ne 0
      then
         err "ERROR: Failed to build the legacy ui" 
         return 1
      fi
      
      status_stage "==> Building UI for version ${vers}"
      build_ui "${sdir}" "${UI_BUILD_TAG}"
      if test $? -ne 0
      then
         err "ERROR: Failed to build the ui" 
         return 1
      fi
      
      status_stage "==> Building Static Assets for version ${vers}"
      build_assetfs "${sdir}" "${GO_BUILD_TAG}"
      if test $? -ne 0
      then
         err "ERROR: Failed to build the static assets" 
         return 1
      fi
      
      if is_set "${do_tag}"
      then
         git add "${sdir}/agent/bindata_assetfs.go"
         if test $? -ne 0
         then
            err "ERROR: Failed to git add the assetfs file" 
            return 1
         fi
      fi
   fi
   
   if is_set "${do_tag}"
   then
      status_stage "==> Tagging version ${vers}"
      tag_release "${sdir}" "${vers}" "${gpg_key}"
      if test $? -ne 0
      then
         err "ERROR: Failed to tag the release" 
         return 1
      fi
   fi
   
   if is_set "${do_build}"
   then
      status_stage "==> Building Consul for version ${vers}"
      build_consul_release "${sdir}" "${GO_BUILD_TAG}"
      if test $? -ne 0
      then
         err "ERROR: Failed to build the Consul binaries" 
         return 1
      fi
      
      status_stage "==> Packaging up release binaries"
      package_release "${sdir}" "${vers}"
      if test $? -ne 0
      then
         err "ERROR: Failed to package the release binaries" 
         return 1
      fi
   fi
   
   status_stage "==> Generating SHA 256 Hashes for Binaries"
   shasum_release "${sdir}/pkg/dist" "consul_${vers}_SHA256SUMS"
   if test $? -ne 0
   then
      err "ERROR: Failed to generate SHA 256 hashes for the release"
      return 1
   fi
   
   if is_set "${do_sha256}"
   then
      sign_release "${sdir}/pkg/dist/consul_${vers}_SHA256SUMS" "${gpg_key}"
      if test $? -ne 0
      then
         err "ERROR: Failed to sign the SHA 256 hashes file"
         return 1
      fi
   fi
         
   return 0    
}