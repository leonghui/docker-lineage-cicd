#!/bin/bash

# Docker build script
# Copyright (c) 2017 Julian Xhokaxhiu
# Copyright (C) 2017 Nicola Corna <nicola@corna.info>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

IFS=','

# cd to working directory
cd $SRC_DIR

if [ -f /root/userscripts/begin.sh ]; then
  echo ">> [$(date)] Running begin.sh"
  /root/userscripts/begin.sh
fi

# If requested, clean the OUT dir in order to avoid clutter
if [ "$CLEAN_OUTDIR" = true ]; then
  echo ">> [$(date)] Cleaning '$ZIP_DIR'"
  cd $ZIP_DIR
  rm *
  cd $SRC_DIR
fi

# Treat DEVICE_LIST as DEVICE_LIST_<first_branch>
if [ ! -z "$DEVICE_LIST" ]; then
  device_list_first_branch="DEVICE_LIST_$(echo $BRANCH_NAME | cut -d ',' -f 1 | sed 's/[^[:alnum:]]/_/g')"
  device_list_first_branch=${device_list_first_branch^^}
  read $device_list_first_branch <<< "$DEVICE_LIST,${!device_list_first_branch}"
fi

# If needed, migrate from the old SRC_DIR structure
if [ -d $SRC_DIR/.repo ]; then
  branch=$(git show -s -C vendor/cm --pretty=%D HEAD)
  branch=$(echo ${branch#*m/} | cut -d ',' -f 1 | sed 's/[^[:alnum:]]/_/g')
  branch=${branch^^}
  mkdir $branch
  mv !($branch) $branch
fi

for branch in $BRANCH_NAME; do
  device_list_cur_branch="DEVICE_LIST_$(sed 's/[^[:alnum:]]/_/g' <<< $branch)"
  device_list_cur_branch=${device_list_cur_branch^^}
  cur_src_dir=$SRC_DIR/$device_list_cur_branch

  if [ ! -z "$branch" ] && [ ! -z "${!device_list_cur_branch}" ]; then

    mkdir -p $cur_src_dir
    cd $cur_src_dir

    # Switch branch (or initialize the repository if it's the first time)
    echo ">> [$(date)] Branch:  $branch"
    echo ">> [$(date)] Devices: ${!device_list_cur_branch}"

    if [ ! -d .repo ]; then
      echo ">> [$(date)] Initializing repository"
      yes | repo init -u https://github.com/lineageos/android.git -b $branch
    fi

    # Copy local manifests to the appropriate folder in order take them into consideration
    echo ">> [$(date)] Copying '$LMANIFEST_DIR/*.xml' to '$cur_src_dir/.repo/local_manifests/'"
    rsync -a --delete --exclude 'roomservice.xml' --include '*.xml' --exclude '*' $LMANIFEST_DIR/ $cur_src_dir/.repo/local_manifests/

    # Reset the current git status of "vendor/cm" (remove previous changes) if the directory exists
    if [ -d "vendor/cm" ]; then
      cd vendor/cm
      git reset -q --hard
      cd $cur_src_dir
    fi

    # Reset the current git status of "frameworks/base" (remove previous changes) if the directory exists
    if [ -d "frameworks/base" ]; then
      cd frameworks/base
      git reset -q --hard
      cd $cur_src_dir
    fi

    # Sync the source code
    echo ">> [$(date)] Syncing repository"
    builddate=$(date +%Y%m%d)
    repo sync -q --force-sync

    android_version=$(sed -n -e 's/^\s*PLATFORM_VERSION := //p' build/core/version_defaults.mk)
    android_version_major=$(cut -d '.' -f 1 <<< $android_version)

    # If needed, apply the microG's signature spoofing patch
    if [ "$SIGNATURE_SPOOFING" = "yes" ] || [ "$SIGNATURE_SPOOFING" = "restricted" ]; then
      # Determine which patch should be applied to the current Android source tree
      patch_name=""
      case $android_version in
        4.4* )    patch_name="android_frameworks_base-KK-LP.patch" ;;
        5.*  )    patch_name="android_frameworks_base-KK-LP.patch" ;;
        6.*  )    patch_name="android_frameworks_base-M.patch" ;;
        7.*  )    patch_name="android_frameworks_base-N.patch" ;;
      esac

      if ! [ -z $patch_name ]; then
        cd frameworks/base
        if [ "$SIGNATURE_SPOOFING" = "yes" ]; then
          echo ">> [$(date)] Applying the standard signature spoofing patch ($patch_name) to frameworks/base"
          echo ">> [$(date)] WARNING: the standard signature spoofing patch introduces a security threat"
          patch --quiet -p1 -i "/root/signature_spoofing_patches/$patch_name"
        else
          echo ">> [$(date)] Applying the restricted signature spoofing patch (based on $patch_name) to frameworks/base"
          sed 's/android:protectionLevel="dangerous"/android:protectionLevel="signature|privileged"/' "/root/signature_spoofing_patches/$patch_name" | patch --quiet -p1
        fi
        git clean -q -f
      else
        echo ">> [$(date)] ERROR: can't find a suitable signature spoofing patch for the current Android version ($android_version)"
        exit 1
      fi
    fi
    cd $cur_src_dir

    echo ">> [$(date)] Setting \"$RELEASE_TYPE\" as release type"
    sed -i '/#.*Filter out random types/d' vendor/cm/config/common.mk
    sed -i '/$(filter .*$(CM_BUILDTYPE)/,+3d' vendor/cm/config/common.mk

    # Set a custom updater URI if a OTA URL is provided
    if ! [ -z "$OTA_URL" ]; then
      echo ">> [$(date)] Adding OTA URL '$OTA_URL' to build.prop"
      sed -i "1s;^;PRODUCT_PROPERTY_OVERRIDES += $OTA_PROP=$OTA_URL\n\n;" vendor/cm/config/common.mk
    fi

    # Add custom packages to be installed
    if ! [ -z "$CUSTOM_PACKAGES" ]; then
      echo ">> [$(date)] Adding custom packages ($CUSTOM_PACKAGES)"
      sed -i "1s;^;PRODUCT_PACKAGES += $CUSTOM_PACKAGES\n\n;" vendor/cm/config/common.mk
    fi

    if [ "$SIGN_BUILDS" = true ]; then
      echo ">> [$(date)] Adding keys path ($KEYS_DIR)"
      sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := $KEYS_DIR/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := $KEYS_DIR/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := $KEYS_DIR/releasekey\n\n;" vendor/cm/config/common.mk
    fi

    if [ "$android_version_major" -ge "7" ]; then
      jdk_version=8
    elif [ "$android_version_major" -ge "5" ]; then
      jdk_version=7
    else
      echo ">> [$(date)] ERROR: $branch requires a JDK version too old (< 7); aborting"
      exit 1
    fi

    echo ">> [$(date)] Using OpenJDK $jdk_version"
    update-java-alternatives -s java-1.$jdk_version.0-openjdk-amd64 > /dev/null 2>&1

    # Prepare the environment
    echo ">> [$(date)] Preparing build environment"
    source build/envsetup.sh > /dev/null

    if [ -f /root/userscripts/before.sh ]; then
      echo ">> [$(date)] Running before.sh"
      /root/userscripts/before.sh
    fi

    for codename in ${!device_list_cur_branch}; do
      cd $cur_src_dir
      currentdate=$(date +%Y%m%d)
      if [ "$builddate" != "$currentdate" ]; then
        # Sync the source code
        echo ">> [$(date)] Syncing repository"
        builddate=$currentdate
        repo sync -q --force-sync
      fi

      if ! [ -z "$codename" ]; then
        if [ "$ZIP_SUBDIR" = true ]; then
          zipsubdir=$codename
          mkdir -p $ZIP_DIR/$zipsubdir
        else
          zipsubdir=
        fi
        if [ "$LOGS_SUBDIR" = true ]; then
          logsubdir=$codename
          mkdir -p $LOGS_DIR/$logsubdir
        else
          logsubdir=
        fi
        los_ver_major=$(sed -n -e 's/^\s*PRODUCT_VERSION_MAJOR = //p' vendor/cm/config/common.mk)
        los_ver_minor=$(sed -n -e 's/^\s*PRODUCT_VERSION_MINOR = //p' vendor/cm/config/common.mk)
        DEBUG_LOG="$LOGS_DIR/$logsubdir/lineage-$los_ver_major.$los_ver_minor-$builddate-$RELEASE_TYPE-$codename.log"

        if [ -f /root/userscripts/pre-build.sh ]; then
          echo ">> [$(date)] Running pre-build.sh for $codename" >> $DEBUG_LOG 2>&1
          /root/userscripts/pre-build.sh $codename >> $DEBUG_LOG 2>&1
        fi

        # Start the build
        echo ">> [$(date)] Starting build for $codename, $branch branch" | tee -a $DEBUG_LOG
        if brunch $codename >> $DEBUG_LOG 2>&1; then
          currentdate=$(date +%Y%m%d)
          if [ "$builddate" != "$currentdate" ]; then
            find out/target/product/$codename -name "lineage-*-$currentdate-*.zip*" -type f -maxdepth 1 -exec sh /root/fix_build_date.sh {} $currentdate $builddate \; >> $DEBUG_LOG 2>&1
          fi

          if [ "$BUILD_DELTA" = true ]; then
            if [ -d "$cur_src_dir/delta_last/$codename/" ]; then
              # If not the first build, create delta files
              echo ">> [$(date)] Generating delta files for $codename" | tee -a $DEBUG_LOG
              cd /root/delta
              if ./opendelta.sh $codename >> $DEBUG_LOG 2>&1; then
                echo ">> [$(date)] Delta generation for $codename completed" | tee -a $DEBUG_LOG
              else
                echo ">> [$(date)] Delta generation for $codename failed" | tee -a $DEBUG_LOG
              fi
              if [ "$DELETE_OLD_DELTAS" -gt "0" ]; then
                /usr/bin/python /root/clean_up.py -n $DELETE_OLD_DELTAS $DELTA_DIR >> $DEBUG_LOG 2>&1
              fi
            else
              # If the first build, copy the current full zip in $cur_src_dir/delta_last/$codename/
              echo ">> [$(date)] No previous build for $codename; using current build as base for the next delta" | tee -a $DEBUG_LOG
              mkdir -p $cur_src_dir/delta_last/$codename/ >> $DEBUG_LOG 2>&1
              find out/target/product/$codename -name 'lineage-*.zip' -type f -maxdepth 1 -exec cp {} $cur_src_dir/delta_last/$codename/ \; >> $DEBUG_LOG 2>&1
            fi
          fi
          # Move produced ZIP files to the main OUT directory
          echo ">> [$(date)] Moving build artifacts for $codename to '$ZIP_DIR/$zipsubdir'" | tee -a $DEBUG_LOG
          cd $cur_src_dir/out/target/product/$codename
          for build in lineage-*.zip; do
            sha256sum $build > $ZIP_DIR/$zipsubdir/$build.sha256sum
          done
          find . -name 'lineage-*.zip*' -type f -maxdepth 1 -exec mv {} $ZIP_DIR/$zipsubdir/ \; >> $DEBUG_LOG 2>&1
        else
          echo ">> [$(date)] Failed build for $codename" | tee -a $DEBUG_LOG
        fi
        # Remove old zips and logs
        if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
          /usr/bin/python /root/clean_up.py -n $DELETE_OLD_ZIPS $ZIP_DIR
        fi
        if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
          /usr/bin/python /root/clean_up.py -n $DELETE_OLD_LOGS $LOGS_DIR
        fi
        # Clean everything, in order to start fresh on next build
        if [ "$CLEAN_AFTER_BUILD" = true ]; then
          echo ">> [$(date)] Cleaning build for $codename" | tee -a $DEBUG_LOG
          rm -rf $cur_src_dir/out/target/product/$codename/ >> $DEBUG_LOG 2>&1
        fi
        if [ -f /root/userscripts/post-build.sh ]; then
          echo ">> [$(date)] Running post-build.sh for $codename" >> $DEBUG_LOG 2>&1
          /root/userscripts/post-build.sh $codename >> $DEBUG_LOG 2>&1
        fi
        echo ">> [$(date)] Finishing build for $codename" | tee -a $DEBUG_LOG
      fi
    done

  fi
done

# Create the OpenDelta's builds JSON file
if ! [ -z "$OPENDELTA_BUILDS_JSON" ]; then
  echo ">> [$(date)] Creating OpenDelta's builds JSON file (ZIP_DIR/$OPENDELTA_BUILDS_JSON)"
  if [ "$ZIP_SUBDIR" != true ]; then
    echo ">> [$(date)] WARNING: OpenDelta requires zip builds separated per device! You should set ZIP_SUBDIR to true"
  fi
  /usr/bin/python /root/opendelta_builds_json.py $ZIP_DIR -o $ZIP_DIR/$OPENDELTA_BUILDS_JSON
fi

# Clean the src directory if requested
if [ "$CLEAN_SRCDIR" = true ]; then
  rm -rf "$SRC_DIR/*"
fi

if [ -f /root/userscripts/end.sh ]; then
  echo ">> [$(date)] Running end.sh"
  /root/userscripts/end.sh
fi

