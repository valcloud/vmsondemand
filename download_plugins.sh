#!/usr/bin/bash
# vpotokov@gmail.com
# Feb 9 2018

set -e

[ $# -eq 0 ] && {
  echo "usage: $0 <file_list>"
  exit 1
}

plist=$1

[ -s $plist ] || {
  echo "Empty parameter file"
  exit 1
}

url_source="http://archives.jenkins-ci.org/plugins"
plugin_dir=$(pwd)/var/lib/jenkins/plugins
rm -rf $plugin_dir
mkdir -p $plugin_dir 

echo "Requested number of plugins for download: "$(wc -w $plist)
echo "...................................................."

installPlugin() {

  pname=$1
  echo "Start download: "$pname
  [ -f ${plugin_dir}/${pname}.hpi -o -f ${plugin_dir}/${pname}.jpi ] && {
    [ "$2" == "1" ] && {
      return 1
    } 
    echo "Skipped: $pname (already installed)"
    return 0
  } || { 
    echo "Installing: $pname"
    curl -L --silent --output ${plugin_dir}/${pname}.hpi  \
    ${url_source}/${pname}/latest/${pname}.hpi
    return 0
  } 

}

for plugin in $(cat $plist); do
    installPlugin "$plugin"
done

changed=1
maxloops=100

while [ "$changed"  == "1" ]; do

  echo "Check for missing dependecies ..."

  [ $maxloops -lt 1 ] && {
    echo "Max loop count reached - probably a bug in this script: $0"
    exit 1
  } 

  ((maxloops--))
  changed=0
  for f in ${plugin_dir}/*.hpi ; do
    deps=$( unzip -p ${f} META-INF/MANIFEST.MF | tr -d '\r' |\
    sed -e ':a;N;$!ba;s/\n //g' | grep -e "^Plugin-Dependencies: " |\
    awk '{ print $2 }' | tr ',' '\n' | awk -F ':' '{ print $1 }' |\
    tr '\n' ' ' )
    for plugin in $deps; do
      installPlugin "$plugin" 1 && changed=1
    done
  done

done

echo "Downloded "$(ls ${plugin_dir}/* | wc -l)" plugins"
echo "..................................................."
echo "Plugins directory: "$plugin_dir
echo "Copy manually with <scp "${plugin_dir}"/*.hpi username@hostname:~/>"

