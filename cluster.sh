#!/usr/bin/env bash

. `dirname $0`/templates.tpl

CONF_ROOT=$HOME/.coreos-utils

function usage {
  local PROG=`basename $0`
  echo "USAGE for $PROG:"
  echo "  $PROG kickstart:
      create and run new cluster named 'coreos' for test or develop"
  echo "  $PROG new <cluster name> [<cluster initial size>]:
      create new cluster. default initial size is 1."
  echo "  $PROG run <cluster name> [<cluster size>]:
      run new cluster. default size is 1. if cluster size is less than initial size,
      it will be modified to initial size."
  echo "  $PROG env <cluster name>:
      environment variables for fleetd."
  echo "  $PROG stop <cluster name>:
      stop running cluster. kill all hosts"
  echo "  $PROG del <cluster name>:
      delete new cluster."
  echo "  $PROG clean <cluster name>:
      remove all members from cluster."
}

function kickstart {
  local NAME=coreos
  echo "-- create 'coreos' cluster configuration in etcd and $CONF_ROOT with initial size 1"
  new $NAME
  echo "-- launch 3 hosts in 'coreos' cluster"
  run $NAME 3
  echo "-- run command './cluster.sh del coreos' in order to stop and delete 'coreos' cluster"
}

function new {
  local NAME=$1
  local SIZE=${2:-1}
  local CLUSTER=`echo -n $NAME | shasum | awk '{print $1}'`

  _config_etcd
  _config_cloud $NAME

  etcdctl ls discovery/$CLUSTER &> /dev/null
  local EXIST=$?
  local CMD=mk
  [[ $EXIST -eq 0 ]] && CMD=update
  etcdctl $CMD discovery/$CLUSTER/_config/size $SIZE &> /dev/null
  echo $CLUSTER
}

function run {
  local NAME=$1
  local SIZE=${2:-1}
  local CLUSTER=`echo -n $NAME | shasum | awk '{print $1}'`
  local CONF=`_cloud_config_path $NAME`

  _config_etcd

  local INIT_SIZE=`etcdctl get discovery/$CLUSTER/_config/size 2> /dev/null`
  [[ $SIZE -lt $INIT_SIZE ]] && SIZE=$INIT_SIZE

  cd $CONF_ROOT

  if [ $SIZE -eq 1 ]; then
    sudo corectl run --channel beta --cloud_config $CONF --name $NAME -d
  else
    for SEQ in `seq -w -f %02g 1 $SIZE`; do
      sudo corectl run --channel beta --cloud_config $CONF --name ${NAME}$SEQ -d
    done
  fi
}

function env {
  local NAME=$1
  local CLUSTER=`echo -n $NAME | shasum | awk '{print $1}'`
  local LEADER

  _config_etcd

  etcdctl ls discovery/$CLUSTER &> /dev/null
  local EXIST=$?

  if [ $EXIST -eq 0 ]; then
    LEADER_NODE=$(etcdctl ls discovery/$CLUSTER | head -1)
    LEADER=$(etcdctl get $LEADER_NODE | cut -d= -f2 | awk -F: 'BEGIN{OFS=":"} {print $1, $2}')
  fi

  echo export FLEETCTL_ENDPOINT=${LEADER}:2379
}

function stop {
  local NAME=$1

  for NODE in `corectl query -a | sed '1d' | grep $NAME\[0-9\]\* | awk '{print $6}'`; do
    corectl kill $NODE
  done

  clean $NAME
}

function del {
  local NAME=$1
  local CLUSTER=`echo -n $NAME | shasum | awk '{print $1}'`

  stop $NAME

  etcdctl ls discovery/$CLUSTER &> /dev/null
  local EXIST=$?

  if [ $EXIST -eq 0 ]; then
    etcdctl rm discovery/$CLUSTER/_config/size &> /dev/null
    etcdctl rmdir discovery/$CLUSTER/_config &> /dev/null
    etcdctl rmdir discovery/$CLUSTER &> /dev/null
  fi

  rm -f $HOME/.coreos-utils/$NAME-init.yml
}

function clean {
  local NAME=$1
  local CLUSTER=`echo -n $NAME | shasum | awk '{print $1}'`

  _config_etcd

  etcdctl ls discovery/$CLUSTER &> /dev/null
  local EXIST=$?

  if [ $EXIST -eq 0 ]; then
    for node in `etcdctl ls discovery/$CLUSTER`; do
      etcdctl rm $node | awk '{print $2}' | awk -F= '{print $2}' | awk -F/ '{print $NF}' | cut -d: -f 1
    done 
  fi
}

function _config_etcd {
  local CONFIG_PATH=`brew --prefix`/opt/etcd/homebrew.mxcl.etcd.plist
  local CONFHASH=fec86c605f860e210a8c19965eb7f39c5dca44ce

  if [ $CONFHASH != `shasum $CONFIG_PATH | awk '{print $1}'` ]; then
    cp $CONFIG_PATH{,.backup} 
    cat <<EOF > $CONFIG_PATH
$(tpl_etcd)
EOF
    echo "Update etcd launchd configuration"
    echo "Restart etcd"
    ln -sfv `brew --prefix`/opt/etcd/*.plist ~/Library/LaunchAgents
    launchctl load ~/Library/LaunchAgents/homebrew.mxcl.etcd.plist &> /dev/null
    launchctl stop homebrew.mxcl.etcd
    launchctl start homebrew.mxcl.etcd
  fi
}

function _config_cloud {
  local NAME=$1

  cat <<EOF > $CONF_ROOT/`_cloud_config_path $NAME`
$(tpl_cloud $NAME)
EOF
}

function _cloud_config_path {
  local NAME=$1

  [[ -d $CONF_ROOT ]] || mkdir -p $CONF_ROOT

  echo -n $NAME-init.yml
}

COMMAND=$1
shift

case $COMMAND in
  kickstart)
    `dirname $0`/prereq.sh
    kickstart $@
    ;;
  new)
    `dirname $0`/prereq.sh
    new $@
    ;;
  run)
    `dirname $0`/prereq.sh
    run $@
    ;;
  env)
    `dirname $0`/prereq.sh
    env $@
    ;;
  stop)
    `dirname $0`/prereq.sh
    stop $@
    ;;
  del)
    `dirname $0`/prereq.sh
    del $@
    ;;
  clean)
    `dirname $0`/prereq.sh
    clean $@
    ;;
  *)
    usage
    ;;
esac
