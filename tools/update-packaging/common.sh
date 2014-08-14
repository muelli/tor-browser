#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

#
# Code shared by update packaging scripts.
# Author: Darin Fisher
#

# -----------------------------------------------------------------------------
QUIET=0

# By default just assume that these tools exist on our path
MAR=${MAR:-mar}
BZIP2=${BZIP2:-bzip2}
MBSDIFF=${MBSDIFF:-mbsdiff}

# -----------------------------------------------------------------------------
# Helper routines

notice() {
  echo "$*" 1>&2
}

verbose_notice() {
  if [ $QUIET -eq 0 ]; then
    notice "$*"
  fi
}

get_file_size() {
  info=($(ls -ln "$1"))
  echo ${info[4]}
}

copy_perm() {
  reference="$1"
  target="$2"

  if [ -x "$reference" ]; then
    chmod 0755 "$target"
  else
    chmod 0644 "$target"
  fi
}

make_add_instruction() {
  f="$1"

  # Used to log to the console
  if [ $2 ]; then
    forced=" (forced)"
  else
    forced=
  fi

  is_extension=$(echo "$f" | grep -c 'distribution/extensions/.*/')
  if [ $is_extension = "1" ]; then
    # Use the subdirectory of the extensions folder as the file to test
    # before performing this add instruction.
    testdir=$(echo "$f" | sed 's/\(.*distribution\/extensions\/[^\/]*\)\/.*/\1/')
    verbose_notice "     add-if: $f$forced"
    echo "add-if \"$testdir\" \"$f\""
  else
    verbose_notice "        add: $f$forced"
    echo "add \"$f\""
  fi
}

make_addsymlink_instruction() {
  link="$1"
  target="$2"

  verbose_notice "        addsymlink: $link -> $target"
  echo "addsymlink \"$link\" \"$target\""
}

make_patch_instruction() {
  f="$1"
  is_extension=$(echo "$f" | grep -c 'distribution/extensions/.*/')
  if [ $is_extension = "1" ]; then
    # Use the subdirectory of the extensions folder as the file to test
    # before performing this add instruction.
    testdir=$(echo "$f" | sed 's/\(.*distribution\/extensions\/[^\/]*\)\/.*/\1/')
    verbose_notice "   patch-if: $f"
    echo "patch-if \"$testdir\" \"$f.patch\" \"$f\""
  else
    verbose_notice "      patch: $f"
    echo "patch \"$f.patch\" \"$f\""
  fi
}

append_remove_instructions() {
  dir="$1"
  filev1="$2"
  filev2="$3"
  if [ -f "$dir/removed-files" ]; then
    prefix=
    listfile="$dir/removed-files"
  elif [ -f "$dir/Contents/MacOS/removed-files" ]; then
    prefix=Contents/MacOS/
    listfile="$dir/Contents/MacOS/removed-files"
  fi
  if [ -n "$listfile" ]; then
    # Map spaces to pipes so that we correctly handle filenames with spaces.
    files=($(cat "$listfile" | tr " " "|"  | sort -r))
    num_files=${#files[*]}
    for ((i=0; $i<$num_files; i=$i+1)); do
      # Map pipes back to whitespace and remove carriage returns
      f=$(echo ${files[$i]} | tr "|" " " | tr -d '\r')
      # Trim whitespace
      f=$(echo $f)
      # Exclude blank lines.
      if [ -n "$f" ]; then
        # Exclude comments
        if [ ! $(echo "$f" | grep -c '^#') = 1 ]; then
          # Normalize the path to the root of the Mac OS X bundle if necessary
          fixedprefix="$prefix"
          if [ $prefix ]; then
            if [ $(echo "$f" | grep -c '^\.\./') = 1 ]; then
              if [ $(echo "$f" | grep -c '^\.\./\.\./') = 1 ]; then
                f=$(echo $f | sed -e 's:^\.\.\/\.\.\/::')
                fixedprefix=""
              else
                f=$(echo $f | sed -e 's:^\.\.\/::')
                fixedprefix=$(echo "$prefix" | sed -e 's:[^\/]*\/$::')
              fi
            fi
          fi
          if [ $(echo "$f" | grep -c '\/$') = 1 ]; then
            verbose_notice "      rmdir: $fixedprefix$f"
            echo "rmdir \"$fixedprefix$f\"" >> "$filev2"
          elif [ $(echo "$f" | grep -c '\/\*$') = 1 ]; then
            # Remove the *
            f=$(echo "$f" | sed -e 's:\*$::')
            verbose_notice "    rmrfdir: $fixedprefix$f"
            echo "rmrfdir \"$fixedprefix$f\"" >> "$filev2"
          else
            verbose_notice "     remove: $fixedprefix$f"
            echo "remove \"$fixedprefix$f\"" >> "$filev1"
            echo "remove \"$fixedprefix$f\"" >> "$filev2"
          fi
        fi
      fi
    done
  fi
}

# List all files in the current directory, stripping leading "./"
# To support Tor Browser updates, skip TorBrowser/Data/Browser/profiles.ini,
# TorBrowser/Data/Browser/profile.default/bookmarks.html and
# TorBrowser/Data/Tor/torrc.
# Skip the channel-prefs.js file as it should not be included in any
# generated MAR files (see bug 306077). Pass a variable name and it will be
# filled as an array.
list_files() {
  count=0

  find . -type f \
    ! -name "channel-prefs.js" \
    ! -name "update.manifest" \
    ! -name "updatev2.manifest" \
    ! -name "temp-dirlist" \
    ! -name "temp-filelist" \
    | sed 's/\.\/\(.*\)/\1/' \
    | sort -r > "temp-filelist"
  while read file; do
    if [ $file = "TorBrowser/Data/Browser/profiles.ini" -o                     \
         $file = "TorBrowser/Data/Browser/profile.default/bookmarks.html" -o   \
         $file = "TorBrowser/Data/Tor/torrc" ]; then
      continue;
    fi
    eval "${1}[$count]=\"$file\""
    (( count++ ))
  done < "temp-filelist"
  rm "temp-filelist"
}

# List all directories in the current directory, stripping leading "./"
list_dirs() {
  count=0

  find . -type d \
    ! -name "." \
    ! -name ".." \
    | sed 's/\.\/\(.*\)/\1/' \
    | sort -r > "temp-dirlist"
  while read dir; do
    eval "${1}[$count]=\"$dir\""
    (( count++ ))
  done < "temp-dirlist"
  rm "temp-dirlist"
}

# List all symbolic links in the current directory, stripping leading "./"
list_symlinks() {
  count=0

  find . -type l \
    | sed 's/\.\/\(.*\)/\1/' \
    | sort -r > "temp-symlinklist"
  while read symlink; do
	target=$(readlink "$symlink")
    eval "${1}[$count]=\"$symlink\""
    eval "${2}[$count]=\"$target\""
    (( count++ ))
  done < "temp-symlinklist"
  rm "temp-symlinklist"
}
