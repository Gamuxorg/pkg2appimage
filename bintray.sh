#!/bin/bash

# Push AppImages and related metadata to Bintray
# https://bintray.com/docs/api/

API=https://api.bintray.com
FILE=$1

[ -f "$FILE" ] || exit

BINTRAY_USER="probono"
BINTRAY_API_KEY=$BINTRAY_API_KEY # env
BINTRAY_REPO="AppImages"
PCK_NAME=$(basename $1)
WEBSITE_URL="http://appimage.org"
ISSUE_TRACKER_URL="https://github.com/probonopd/AppImages/issues"
VCS_URL="https://github.com/probonopd/AppImages.git" # Mandatory for packages in free Bintray repos

which curl || exit 1
which bsdtar || exit 1 # https://github.com/libarchive/libarchive/wiki/ManPageBsdtar1 ; isoinfo cannot read zisofs
which grep || exit 1

if [ ! $(env | grep BINTRAY_API_KEY ) ] ; then
  echo "Environment variable \$BINTRAY_API_KEY missing"
  exit 1
fi

# Do not upload artefacts generated as part of a pull request
if [ $(env | grep TRAVIS_PULL_REQUEST ) ] ; then
  if [ "$TRAVIS_PULL_REQUEST" != "false" ] ; then
    echo "Not uploading since this is a pull request"
    exit 0
  fi
fi

CURL="curl -u${BINTRAY_USER}:${BINTRAY_API_KEY} -H Content-Type:application/json -H Accept:application/json"

# Get metadata from the desktop file inside the AppImage
DESKTOP=$(bsdtar -tf "${FILE}" | grep ^./[^/]*.desktop$ | head -n 1)
# Extract the description from the desktop file

echo "* DESKTOP $DESKTOP"

PCK_NAME=$(bsdtar -f "${FILE}" -O -x ./"${DESKTOP}" | grep -e "^Name=" | head -n 1 | sed s/Name=//g | cut -d " " -f 1 | xargs)
if [ "$PCK_NAME" == "" ] ; then
  bsdtar -f "${FILE}" -O -x ./"${DESKTOP}"
  echo "PCK_NAME missing in ${DESKTOP}, exiting"
  exit 1
else
  echo "* PCK_NAME $PCK_NAME"
fi

DESCRIPTION=$(bsdtar -f "${FILE}" -O -x ./"${DESKTOP}" | grep -e "^Comment=" | sed s/Comment=//g)

ICONNAME=$(bsdtar -f "${FILE}" -O -x "${DESKTOP}" | grep -e "^Icon=" | sed s/Icon=//g)

# Look for .DirIcon first
ICONFILE=$(bsdtar -tf "${FILE}" | grep /.DirIcon$ | head -n 1 )

# Look for svg next
if [ "$ICONFILE" == "" ] ; then
 ICONFILE=$(bsdtar -tf "${FILE}" | grep ${ICONNAME}.svg$ | head -n 1 )
fi

# If there is no svg, then look for pngs in usr/share/icons and pick the largest
if [ "$ICONFILE" == "" ] ; then
  ICONFILE=$(bsdtar -tf "${FILE}" | grep usr/share/icons.*${ICONNAME}.png$ | sort -V | tail -n 1 )
fi

# If there is still no icon, then take any png
if [ "$ICONFILE" == "" ] ; then
  ICONFILE=$(bsdtar -tf "${FILE}" | grep ${ICONNAME}.png$ | head -n 1 )
fi

if [ ! "$ICONFILE" == "" ] ; then
  echo "* ICONFILE $ICONFILE"
  bsdtar -f "${FILE}" -O -x "${ICONFILE}" > /tmp/_tmp_icon
  echo "xdg-open /tmp/_tmp_icon"
fi

# Check if there is appstream data and use it
APPDATANAME=$(echo ${DESKTOP} | sed 's/.desktop/.appdata.xml/g' )
APPDATAFILE=$(bsdtar -tf "${FILE}" | grep ${APPDATANAME}$ | head -n 1)
APPDATA=$(bsdtar -f "${FILE}" -O -x "${APPDATAFILE}")
if [ "$APPDATA" == "" ] ; then
  echo "* APPDATA missing"
else
  echo "* APPDATA found"
  DESCRIPTION=$(echo $APPDATA | grep -o -e "<description.*description>" | sed -e 's/<[^>]*>//g' | xargs)
fi

if [ "$DESCRIPTION" == "" ] ; then
  bsdtar -f "${FILE}" -O -x ./"${DESKTOP}"
  echo "DESCRIPTION missing and no Comment= in ${DESKTOP}, exiting"
  exit 1
else
  echo "* DESCRIPTION $DESCRIPTION"
fi

if [ "$VERSION" == "" ] ; then
  echo "* VERSION missing, trying to get from the filename (separator=-)"
  VERSION=$(basename $FILE | sed 's/.AppImage//g' | sed 's/x86_64//g' | sed 's/i386//g' | sed 's/i686//g' | cut -d "-" -f 2 )
fi

if [ "$VERSION" == "" ] ; then
  echo "* VERSION missing, trying to get from the filename (separator=-)"
  VERSION=$(basename $FILE | sed 's/.AppImage//g' | sed 's/x86_64//g' | sed 's/i386//g' | sed 's/i686//g' | cut -d "_" -f 2 )
fi

if [ "$VERSION" == "" ] ; then
  echo "* VERSION missing, exiting"
  exit 1
else
  echo "* VERSION $VERSION"
fi

# exit 0
##########

echo ""
echo "Creating package ${PCK_NAME}..."
    data="{
    \"name\": \"${PCK_NAME}\",
    \"desc\": \"${DESCRIPTION}\",
    \"desc_url\": \"auto\",
    \"website_url\": [\"${WEBSITE_URL}\"],
    \"vcs_url\": [\"${VCS_URL}\"],
    \"issue_tracker_url\": [\"${ISSUE_TRACKER_URL}\"],
    \"licenses\": [\"MIT\"],
    \"labels\": [\"AppImage\", \"AppImageKit\"]
    }"
${CURL} -X POST -d "${data}" ${API}/packages/${BINTRAY_USER}/${BINTRAY_REPO}

echo ""
echo "Uploading and publishing ${FILE}..."
${CURL} -T ${FILE} "${API}/content/${BINTRAY_USER}/${BINTRAY_REPO}/${PCK_NAME}/${VERSION}/$(basename ${FILE})?publish=1&override=1"

# Workaround for as long as zsync is not available on Travis
wget -c https://github.com/probonopd/AppImages/releases/download/1/zsyncmake
chmod a+x zsyncmake
export PATH=./:$PATH

if [ $(which zsyncmake) ] ; then
  echo ""
  echo "Uploading and publishing zsync file for ${FILE}..."
  # Workaround for:
  # https://github.com/probonopd/zsync-curl/issues/1
  zsyncmake -u http://dl.bintray.com/probono/AppImages/$(basename ${FILE}) ${FILE} -o ${FILE}.zsync
  ${CURL} -T ${FILE}.zsync "${API}/content/${BINTRAY_USER}/${BINTRAY_REPO}/${PCK_NAME}/${VERSION}/$(basename ${FILE}).zsync?publish=1&override=1"
else
  echo "zsyncmake not found, skipping zsync file generation and upload"
fi

if [ $(env | grep TRAVIS_JOB_ID ) ] ; then
echo ""
echo "Adding Travis CI log to release notes..."
BUILD_LOG="https://api.travis-ci.org/jobs/${TRAVIS_JOB_ID}/log.txt?deansi=true"
    data='{
  "bintray": {
    "syntax": "markdown",
    "content": "'${BUILD_LOG}'"
  }
}'
${CURL} -X POST -d "${data}" ${API}/packages/${BINTRAY_USER}/${BINTRAY_REPO}/${PCK_NAME}/versions/${VERSION}/release_notes
fi

# Seemingly this works only after the second time running this script - thus disabling for now (FIXME)
# echo ""
# echo "Adding ${FILE} to download list..."
# sleep 5 # Seemingly needed
#     data="{
#     \"list_in_downloads\": true
#     }"
# ${CURL} -X PUT -d "${data}" ${API}/file_metadata/${BINTRAY_USER}/${BINTRAY_REPO}/$(basename ${FILE})
# echo "TODO: Remove earlier versions of the same architecture from the download list"

# echo ""
# echo "TODO: Uploading screenshot for ${FILE}..."
