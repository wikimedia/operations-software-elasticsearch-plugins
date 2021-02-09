#!/bin/bash


ROOT_DIR=$1
PLUGIN_LIST=$2
ELASTICSEARCH_VERSION=$3

temp_dir=$(mktemp -d)

set -e
trap "{ rm -f $LOCKFILE; }" EXIT

for plugin_def in `cat $PLUGIN_LIST | grep -v '^#'`; do
    rm -rf "${temp_dir}/plugin"
    rm -rf "${temp_dir}/plugin.zip"
    url="$(echo $plugin_def | cut -d',' -f1 | sed -e 's/$ELASTICSEARCH_VERSION/'$ELASTICSEARCH_VERSION/g )"
    echo "Downloading $url ..."
    curl -fLo ${temp_dir}/plugin.zip $url
    key=$(echo $plugin_def | cut -d',' -f2)
    if [ $key != 'none' ]; then
        curl -fLo "${temp_dir}/plugin.zip.asc" "$url.asc"
        rm -f "${temp_dir}/keyring.gpg"
        echo "Verifying gpg signature..."
        gpg --no-default-keyring --keyring "${temp_dir}/keyring.gpg" --recv-keys "${key}"
        gpg --no-default-keyring --keyring "${temp_dir}/keyring.gpg" --verify "${temp_dir}/plugin.zip.asc" "${temp_dir}/plugin.zip"
    else
        echo "WARNING trying to download $url without a signature file"
    fi
    unzip "${temp_dir}/plugin.zip" -d "${temp_dir}/plugin"
    if [ ! -d "${temp_dir}/plugin/elasticsearch" ]; then
        rm -f "${temp_dir}/broken_plugin" && \
        mv "${temp_dir}/plugin" "${temp_dir}/broken_plugin" && \
        mkdir -p "${temp_dir}/plugin/" && \
        mv "${temp_dir}/broken_plugin" "${temp_dir}/plugin/elasticsearch" && \
        echo "Fixed broken plugin: ${url}" || \
        echo "WARNING broken plugin detected : ${url}, please investigate"
    fi

    plugin_desc=${temp_dir}/plugin/elasticsearch/plugin-descriptor.properties
    if [ ! -f "$plugin_desc" ]; then
        echo "${plugin_desc} File not found, plugin broken?"
        exit 1
    fi
    plugin_es_version=`grep '^elasticsearch.version=' ${plugin_desc}`
    plugin_es_version="${plugin_es_version##*=}"
    plugin_version=`grep '^version=' ${plugin_desc}`
    plugin_version="${plugin_version##*=}"
    plugin_name=`grep '^name=' ${plugin_desc}`
    plugin_name="${plugin_name##*=}"
    echo "Found matching es version ${plugin_es_version}"
    if [ "${plugin_es_version}" != "${ELASTICSEARCH_VERSION}" ]; then
      echo "${plugin_name} does not match elastic version ${ELASTICSEARCH_VERSION}"
      exit 1
    fi
    mkdir -p "${temp_dir}/deploy/${plugin_name}"
    cp -a "${temp_dir}/plugin/elasticsearch/." "${temp_dir}/deploy/${plugin_name}"
done

mkdir -p "${ROOT_DIR}/usr/share/elasticsearch/plugins/"
cp -a "${temp_dir}"/deploy/* "${ROOT_DIR}/usr/share/elasticsearch/plugins/"
