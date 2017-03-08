#!/usr/bin/env bash

set -e


MVN_DATA="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GIT_REPO="$( cd $MVN_DATA/.. && pwd)"
cd $MVN_DATA
MVN=mvn
ELASTICSEARCH_VERSION=`grep '<elasticsearch.version>' ${MVN_DATA}/pom.xml | sed -e 's/.*<elasticsearch.version>\(.*\)<\/elasticsearch.version>.*/\1/'`
if [ -z "$ELASTICSEARCH_VERSION" ]; then
  echo "No elastic version defined in $MVN_DATA/pom.xml";
  exit 1;
fi

ELASTIC_PLUGINS="analysis-icu analysis-stempel"

temp_dir=$(mktemp -d)

echo "using ${temp_dir} as temporary directory for downloads"

function cleanup {
  echo "removing temporary directory ${temp_dir}"
  rm -rf ${temp_dir}
}
trap cleanup EXIT

function show_help {
  cat << EOF
Usage: ${0##*/} [upload-archiva|prepare-commit]

upload-archiva: downloads plugin .zip files from https://artifacts.elastic.co
                and upload them to archiva
prepare-commit: prepares a commit with the updated plugins for the version of
                elasticsearch defined in pom.xml

===============================================================================
*prerequisites*: the pom.xml must be updated with the correct elasticsearch
                 version and the correct plugin dependencies

EOF
  exit 1
}

function install_elastic_plugins_locally {
  for plugin in ${ELASTIC_PLUGINS}; do
    plugin_filename=${plugin}-${ELASTICSEARCH_VERSION}.zip
    curl -o ${temp_dir}/${plugin_filename} \
      https://artifacts.elastic.co/downloads/elasticsearch-plugins/${plugin}/${plugin_filename}
    $MVN install:install-file \
      -Dfile=${temp_dir}/${plugin_filename} \
      -DgroupId=org.elasticsearch.plugin \
      -DartifactId=${plugin} \
      -Dversion=${ELASTICSEARCH_VERSION} \
      -Dpackaging=zip \
      -DgeneratePom=true
    unzip ${temp_dir}/${plugin_filename} -d ${temp_dir}
    $MVN install:install-file \
      -Dfile=${temp_dir}/elasticsearch/${plugin}-${ELASTICSEARCH_VERSION}.jar \
      -DgroupId=org.elasticsearch.plugin \
      -DartifactId=${plugin} \
      -Dversion=${ELASTICSEARCH_VERSION} \
      -Dpackaging=jar \
      -DgeneratePom=true
    rm -rf ${temp_dir}/elasticsearch
  done
}

function deploy_jars_to_archiva {
  $MVN -Dmdep.copyPom=true -DincludeScope=runtime clean dependency:copy-dependencies

  echo "The following files are going to be uploaded to archiva"
  ls target/dependency
  echo "press [Ctrl]-[C] to abort or [Enter] to continue..."
  read

  for pom in target/dependency/*.pom; do
    $MVN deploy:deploy-file \
      -DrepositoryId=archiva.wikimedia.org \
      -Durl=https://archiva.wikimedia.org/repository/mirrored \
      -Dfile="${pom%%.pom}.jar" \
      -DgeneratePom=false \
      -DpomFile="${pom}"
  done
}

function check_jar_on_archiva {
  sha1=`sha1sum $1 | cut -d' ' -f1`
  jar_name=`basename $1`
  echo "Checking ${jar_name} with SHA1 ${sha1}"
  link_dest=`rsync -an rsync://archiva.wikimedia.org/archiva/git-fat/${sha1} | sed -e 's/.* -> \(.*\)/\1/'`
  if [ -z ${link_dest} ]; then
    echo $1 not found in archiva.wikimedia.org
    exit 1
  fi
  archiva_jar_name=`basename ${link_dest}`
  if [ x${archiva_jar_name} != x${jar_name} ]; then
    echo "${archiva_jar_name} does not match jar name ${jar_name}"
    exit 1;
  fi;
}

function update_git_deployment_repo {
  $MVN -DoutputDirectory=target/plugins clean dependency:copy

  for plugin in `ls ${MVN_DATA}/target/plugins`; do
    rm -rf ${temp_dir}/plugin
    mkdir -p ${temp_dir}/plugin
    unzip ${MVN_DATA}/target/plugins/${plugin} -d ${temp_dir}/plugin
    plugin_desc=${temp_dir}/plugin/elasticsearch/plugin-descriptor.properties
    plugin_es_version=`grep '^elasticsearch.version=' ${plugin_desc}`
    plugin_es_version=${plugin_es_version##*=}
    plugin_version=`grep '^version=' ${plugin_desc}`
    plugin_version=${plugin_version##*=}
    echo Found matching es version ${plugin_es_version}
    if [ ${plugin_es_version} != ${ELASTICSEARCH_VERSION} ]; then
      echo ${plugin} does not match elastic version ${ELASTICSEARCH_VERSION}
      exit 1
    fi
    for jar in `find ${temp_dir}/plugin/elasticsearch -name '*.jar'`; do
      check_jar_on_archiva ${jar}
    done
    name=${plugin##*/}
    name=`basename ${name} -${plugin_version}.zip`
    mkdir -p ${temp_dir}/deploy/${name}
    cp -a ${temp_dir}/plugin/elasticsearch/. ${temp_dir}/deploy/${name}
  done

  for deployed in `find ${temp_dir}/deploy -maxdepth 1 -mindepth 1 -type d`; do
    echo ${deployed}
    name=`basename ${deployed}`
    if [ -d ${GIT_REPO}/${name} ]; then
      git rm -r ${GIT_REPO}/${name}
    fi
    mkdir -p ${GIT_REPO}/${name}
    cp -a ${deployed}/. ${GIT_REPO}/${name}
    git add ${GIT_REPO}/${name}
  done
}

command="$1"
case ${command} in
  upload-archiva)
  install_elastic_plugins_locally
  $MVN clean pgpverify:check
  deploy_jars_to_archiva
  ;;

  prepare-commit)
  $MVN clean pgpverify:check
  update_git_deployment_repo
  ;;

  *)
  show_help
  ;;
esac
