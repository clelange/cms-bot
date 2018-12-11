#!/bin/sh -ex
function get_data ()
{
  echo "$SYSTEM_DATA" | tr ';' '\n' | grep "^DATA_$1=" | sed 's|.*=||'
}

SCRIPT_DIR=$(cd $(dirname $0); /bin/pwd)
TARGET=$1
CLEANUP_WORKSPACE=$2
SSH_OPTS="-q -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

#Check unique slave conenction
if [ "${SLAVE_UNIQUE_TARGET}" = "YES" ] ; then
  if [ `pgrep -f " ${TARGET} " | grep -v "$$" | wc -l` -gt 1 ] ; then exit 99 ; fi
fi
DOCKER_IMG_HOST=$(grep '>DOCKER_IMG_HOST<' -A1 ${HOME}/nodes/${JENKINS_SLAVE_NAME}/config.xml | tail -1  | sed 's|[^>]*>||;s|<.*||')
JENKINS_SLAVE_JAR_MD5=$(md5sum ${HOME}/slave.jar | sed 's| .*||')
scp -p $SSH_OPTS ${SCRIPT_DIR}/system-info.sh "$TARGET:~/system-info.sh"
SYSTEM_DATA=$((ssh -n $SSH_OPTS $TARGET "~/system-info.sh '${JENKINS_SLAVE_JAR_MD5}' '${WORKSPACE}' '${DOCKER_IMG_HOST}' '${CLEANUP_WORKSPACE}'" || echo "DATA_ERROR=Fail to run system-info.sh") | grep '^DATA_' | tr '\n' ';')

if [ $(get_data ERROR | wc -l) -gt 0 ] ; then
  echo $DATA | tr ';' '\n'
  exit 1
fi

xenv=""
case $(get_data SHELL) in
  */tcsh|*/csh) xenv="env" ;;
esac

#Check slave workspace size in GB
if [ "${SLAVE_MAX_WORKSPACE_SIZE}" != "" ] ; then
  if [ $(get_data WORKSPACE_SIZE) -lt $SLAVE_MAX_WORKSPACE_SIZE ] ; then exit 99 ; fi
fi

REMOTE_USER_ID=$(get_data REMOTE_USER_ID)
JENKINS_PORT=$(pgrep -x -a  -f ".*httpPort=.*" | tail -1 | tr ' ' '\n' | grep httpPort | sed 's|.*=||')
JENKINS_URL_LOCAL=$(echo ${JENKINS_URL} | sed "s|.*://[^/]*/|http://localhost:${JENKINS_PORT}/|")
JENKINS_CLI_OPTS="-jar ${HOME}/jenkins-cli.jar -i ${HOME}/.ssh/id_dsa -s ${JENKINS_URL_LOCAL} -remoting"
if [ $(cat ${HOME}/nodes/${JENKINS_SLAVE_NAME}/config.xml | grep '<label>' | grep 'no_label' | wc -l) -eq 0 ] ; then
  slave_labels=""
  case ${SLAVE_TYPE} in
  *dmwm* ) echo "Skipping auto labels" ;;
  aiadm* ) echo "Skipping auto labels" ;;
  lxplus* )
    slave_labels=$(get_data SLAVE_LABELS)
    ;;
  * )
    slave_labels="auto-label $(get_data SLAVE_LABELS)"
    case ${SLAVE_TYPE} in
      cmsbuild*|vocms* ) slave_labels="${slave_labels} cloud cmsbuild release-build";;
      cmsdev*   ) slave_labels="${slave_labels} cloud cmsdev";;
    esac
    case $(get_data HOST_CMS_ARCH) in
      *_aarch64|*_ppc64le ) slave_labels="${slave_labels} release-build cmsbuild";;
    esac
    ;;
  esac
  slave_labels=$(echo ${slave_labels} | sed 's|  *| |g;s|^ *||;s| *$||')
  if [ "X${slave_labels}" != "X" ] ; then java ${JENKINS_CLI_OPTS} groovy ${SCRIPT_DIR}/set-slave-labels.groovy "${JENKINS_SLAVE_NAME}" "${slave_labels}" ; fi
fi
if [ $(get_data JENKINS_SLAVE_SETUP) = "false" ] ; then
  java ${JENKINS_CLI_OPTS} build 'jenkins-test-slave' -p SLAVE_CONNECTION=${TARGET} -p RSYNC_SLAVE_HOME=true -s || true
fi
KRB5_FILENAME=$(echo $KRB5CCNAME | sed 's|^FILE:||')
if [ $(get_data SLAVE_JAR) = "false" ] ; then scp -p $SSH_OPTS ${HOME}/slave.jar $TARGET:$WORKSPACE/slave.jar ; fi
scp -p $SSH_OPTS ${KRB5_FILENAME} $TARGET:/tmp/krb5cc_${REMOTE_USER_ID}
rm -f ${KRB5_FILENAME}
extra_env="KRB5CCNAME=FILE:/tmp/krb5cc_${REMOTE_USER_ID}"
case $(get_data SHELL) in
  */tcsh|*/csh) extra_env="env ${extra_env}" ;;
esac
ssh $SSH_OPTS $TARGET "${xenv} KRB5CCNAME=FILE:/tmp/krb5cc_${REMOTE_USER_ID} java -jar $WORKSPACE/slave.jar -jar-cache $WORKSPACE/tmp"
