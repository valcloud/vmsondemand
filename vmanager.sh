#!/usr/bin/bash
# Author: Valerii Potokov <vpotokov@gmail.com>
# May 22th 2015

# If virtual image is available through http   
# readonly BASEURL="http://.."
# Otherwise it is reachable from nfs 
readonly DAEMON_PID=$$
readonly BASEURL="/data/vmmaster/images_box"
readonly CENTOS_IMG="centos-template.box"
readonly CENTOS_IMG_SELENIUM="centos-selenium-template.box"

# This is a template assuming to manage different OS images, otherwise can skip
readonly OPENSUSE_IMG="...box"

# The larger size/configuration images may require longer time to start 
readonly BOOT_TIMEOUT=900

PASSWORD=<password>

# readonly SCRIPT_DIR=$(cd $(dirname $0) && pwd)
# readonly REPO_HOST=${SCRIPT_DIR%%"/repo"}/
# read/only REPO_DIR='config.vm.synced_folder "${REPO_HOST}", "/repo"'

DEVNULL=/dev/null
ERROR=0
BOXDIR="/data/vmmaster/vagrant-"
UTA="/data/vmmaster/uta"
CONFDIR=${UTA}"/config"
LOGDIR=${CONFDIR}/log
ALL=${UTA}"/state/.vm_all.status"
UPDATE=${UTA}"/state/.vm_update.status"
REGISTER=${UTA}"/state/.vm_register.status"
QUEUE=${UTA}"/state/.vm_queue.status"
SPAWNING=${UTA}"/state/.vm_spawning.status"
_PID=${UTA}"/vmanager.pid"
SELENIUM="no"
BACKGROUND="no"
BUILD_VMS_LIST='
vm1
vm2
'
JLINK="http://192.168.10.121:8080/"
 

# Provide local ip address mapping for host based virtual machines
declare -A ipmap
ipmap["vm1"]=192.168.10.30
ipmap["vm2"]=192.168.10.31
# ipmap["vm3"]=192.168.10.32
ipmap["windows1"]=192.168.10.55
ipmap["windows2"]=192.168.10.56

# groovy scripts

readonly SCRIPT_ALL='
  import hudson.model.* ;
  def allItems(items) {
   node = "new" ;
   progress = "new" ;
   for (item in items) {
    if (item.class.canonicalName != "com.cloudbees.hudson.plugins.folder.Folder") {
      if(item.name != "_OUTPUT_ENVIRONMENT_VARIABLES") {
        if (item.getLastBuild()) {
          node = item.getLastBuild().getBuiltOn().getNodeName() ;
          progress = item.getLastBuild().isInProgress() ;
        }
        ; println(String.format("Job name: %-37s %-10s Running: %-8s", item.name, node, progress)) ;
      }
    }
   }
  }
  ; allItems(Hudson.instance.items)
'

# return a node name regardless it's online or offline
# there is no duplication of the records for job_name field
readonly SCRIPT2_ALL='
  import hudson.model.* ;
  def allItems(items) {
   node = "new" ;
   progress = "new" ;
   for (item in items) {
    if (item.class.canonicalName != "com.cloudbees.hudson.plugins.folder.Folder") {
      if(item.name != "_OUTPUT_ENVIRONMENT_VARIABLES") {
        if (item.getLastBuild()) {
          node = item.getLastBuild().getBuiltOn().getNodeName() ;
          progress = item.getLastBuild().isInProgress() ;
        }
        ; println(String.format("%-37s %-10s %-8s", item.name, node, progress)) ;
      }
    }
   }
  }
  ; allItems(Hudson.instance.items)
'

[ $(whoami) == "tomcat" ] || {
   echo "Should run it just as tomcat user!"
   exit 1
}

print_message() {
   echo
   echo $1
   echo
}

usage() {
   echo "Common usage: ./vmanager -m <mode>
                                     -n <name>

   Options:
      -d <dir>   Virtual machine home directory
      -h         Print this message
      -i <url>   URL link to virtual machine image
      -m <mode>  Subcommand (setup or cleanup)
      -n <name>  Virtual machine name
      -s         Virtual machine with Selenium provisioning
      -b         Run in background in daemon mode, should be supplied also with &

   More details see with -h option.
   
   " 
   return 0
}

help() {
   echo "

The vmanager utility provides CLI for the most common actions
...

   Usage Examples: 

   vm -m setup -n centos1             # create new <vm1> VM
   vm -m setup -n centos11 -s         # create new <vm1> VM with Selenium environment 
   vm -m halt -n centos1              # shutdown <vm1> VM
   vm -m up -n centos1                # start <vm1> VM
   vm -m reload -n centos1            # reload <vm1> VM
   vm -m cleanup -n centos1           # destroy <vm1> VM 
   vm -m list                         # show all currently acivated VMs 
   vm -m start                        # start all previously running VMs
                                      # targeting the server boot
   vm -m stop                         # halt all running VMs
                                      # targeting the server shutdown
   vm -m remove                       # removes all active VBoxHeadless processes,
                                      # use it with caution just when you have a good reason
   vm -m help                         # showns all available options
   vm -b &                            # run as a daemon, all other options are ignored 
 
   Note: 'vm' is the alias that should be configured in your environment
         (e.g. in .bashrc) pointing to the actual vmanager utility 

   The only mandatory option is '-m'.
   See the above when '-n' option is applicable .
   The '-s' option is applicable just for Selenium VM creation .
   The '-b' option is for running in background should follow '&' at the end.
   "
   return 0
}

sanity_check() {
   local exit_code=0
   node=$1
   ssh tomcat@${node} "hostname ; exit" || ((exit_code++))
   return $exit_code
}

vms_initial() {
   # assuming all available and not running nodes are new
   # otherwise check vm's history trace 
   local pwd=$(pwd)
   local vm_name=
   local job_name=
   local tmp="/tmp/Ksin7U46_run"
   local tmp_script="/tmp/iKuI78_uime"
   local script=${SCRIPT2_ALL}
   local flag="no"
   local time=$(time_millis)
   >| $tmp
   >| ${tmp}.off
   >| $REGISTER
   >| $QUEUE
   rm -rf $SPAWNING
   # echo "Check all available builds virtual machines"
   # echo "..........................................."
   for i in $BUILD_VMS_LIST ; do
      sanity_check $i && {
         # all currently online nodes
         echo $i >> $tmp
      } || {
         # all currently offline nodes
         echo $i >> ${tmp}.off
      }
   done
   echo $script > $tmp_script
   cd $UAT
   java -jar jenkins-cli.jar -s $JLINK groovy \
      $tmp_script  > ${tmp_script}.out --username jenkins.slave --password $PASSWORD 2>/dev/null
   sort -k3 -r ${tmp_script}.out > ${tmp_script}.out.sorted
   for i in $(cat $tmp) ; do
      job_name="new"
      flag="no"
      while read line; do   
         vm_name=$(echo $line | awk '{print $2}')
         echo $i | grep $vm_name >/dev/null 2>&1
         (($?)) || { # is not master 
            job_name=$(echo $line | awk '{print $1}')
            [[ "$(echo $line | awk '{print $3}')" == "true" ]] && { 
               flag="yes" # is not master and busy
            }
         } 
      done < ${tmp_script}.out.sorted 
      [[ "$flag" == "yes" ]] && {
        echo ${i}" "${job_name}" wait "$time >> $REGISTER
      } || {
        echo ${i}" "${job_name}" new "$time >> $REGISTER
      }
   done
   # add which currently are not availble
   for i in $(cat ${tmp}.off) ; do
       echo ${i}" off off "$time >> $REGISTER
   done 
   rm -rf ${tmp}*
   rm -rf ${tmp_script}*
   cd $pwd
   return 0
}

check_all_vms() {
   local pwd=$(pwd)
   local tmp=/tmp/s45n_sVk12runtime
   echo $SCRIPT_ALL > $tmp 
   cd $UTA 
   java -jar jenkins-cli.jar -s $JLINK groovy $tmp > ${tmp}.out --username jenkins.slave --password $PASSWORD 2>/dev/null
   sort -k3 -r ${tmp}.out > $ALL 
   cd $pwd
   rm -rf ${tmp}*
   return 0
}

time_millis() {
   local pwd=$(pwd)
   local tmp=/tmp/s48n_sVp14runtime
   local script='
   import static java.util.Calendar.* ; 
   def now = Calendar.instance ;
   date = now.time ; 
   millis = date.time ;
   println millis ;
   '
   echo $script > $tmp 
   cd $UTA 
   java -jar jenkins-cli.jar -s $JLINK groovy $tmp  > ${tmp}.out --username jenkins.slave --password $PASSWORD 2>/dev/null
   cat ${tmp}.out 
   rm -rf ${tmp}.out
}

# vm_name - includes a node name running
# job_name - job name running 
# time - timestamp of this iteration 
# there is no duplication of the records for vm_name and job_name fields
# sorted by node name in $UPDATE
update_running() {
      local vm_name=
      local job_name=
      local tmp=/tmp/s49p_tVl12runtime.out
      local time=$(time_millis) 
      >| $tmp 
      while read line; do
        [ "$(echo $line | awk '{print $6}')" == "true" ] && {
           # Skip all master related jobs and process just slaves
           [ "$(echo $line | awk '{print $4}')" == "Running:" ] || {
              # Care just about slaves  
              vm_name=$(echo $line | awk '{print $4}')
              echo $BUILD_VMS_LIST | grep $vm_name >/dev/null 2>&1
              (($?)) || {
                 job_name=$(echo $line | awk '{print $3}')           
                 echo ${vm_name}" "${job_name}" "$time >> $tmp 
              }
           }
        } 
      done < $ALL  
      sort -k1 $tmp > ${tmp}.sort
      mv ${tmp}.sort $UPDATE 
      rm -rf ${tmp}* 
}

# return second field if the key value matches
read_field2() {
   local key=$1
   local table=$2
   while read line; do
      echo $line | grep ${key}" " &>/dev/null
      (($?)) || {
        echo $line | awk '{print $2}' 
      }
   done < $table
}

update_queue() {
   local vm_name=
   local job_name=
   local flag=
   local time=$(time_millis)
   local tmp=/tmp/kjl8IKOjkl41_run
   # stated as running in the registry
   >| $tmp 
   # found as running in the current iteration
   >| ${tmp}.1
   # registered as running items
   while read line; do
      vm_name=$(echo $line | awk '{print $1}')
      [[ "$(echo $line | awk '{print $3}')" == "wait" ]] && {
         echo $vm_name >> $tmp
      }
   done < $REGISTER
   sort $tmp | uniq -u > ${tmp}.sort
   # currently running 
   [ -s $UPDATE ] && {
       while read line; do
          echo $line | awk '{print $1}' >> ${tmp}.1
       done < $UPDATE
   }
   sort ${tmp}.1 | uniq -u > ${tmp}.1.sort

   # new running 
   newrunning=$(comm -23 ${tmp}.1.sort ${tmp}.sort)
   [ -n "$newrunning" ] && {
      # update registry with new running items status
      cp $REGISTER ${REGISTER}.copy
      for i in $newrunning ; do
        while read line; do
           vm_name=$(echo $line | awk '{print $1}')
           job_name=$(echo $line | awk '{print $2}')
           [[ "$i" == "$(echo $line | awk '{print $1}')" ]] && {
              # it is expected had <new> status that we update as <wait>
              remove_line $vm_name ${REGISTER}.copy
              echo ${vm_name}" "${job_name}" wait "$time >> ${REGISTER}.copy
           }
        done < $REGISTER
      done
      mv ${REGISTER}.copy $REGISTER
   }

   # appeared as are not running anymore
   notrunning=$(comm -23 ${tmp}.sort ${tmp}.1.sort)

   # add into the QUEUE, but leave registry as it is with wait state

   [ -n "$notrunning" ] && {
      for i in "$notrunning" ; do
         echo ${i} >> $QUEUE
      done
   }
   sort $QUEUE | uniq -u > ${QUEUE}.copy
   mv ${QUEUE}.copy $QUEUE

   # update registry with renew state

   [ -s $QUEUE ] && { 
     cp $REGISTER ${REGISTER}.copy
     for i in $(cat $QUEUE) ; do 
        job_name=$(read_field2 $i $UPDATE)
        remove_line $i ${REGISTER}.copy
        echo $i" "${job_name}" renew "$time >> ${REGISTER}.copy
     done 
     mv ${REGISTER}.copy $REGISTER
   }
   rm -rf ${tmp}*
}

remove_line() {
  local line=$1" "
  local file=$2 
  [[ -s $file ]] && {
     awk '!/'"$line"'/' $file > ${file}.removed 
     mv ${file}.removed $file 
  }
}

check_status() {
  local vm_name=
  local time=$(time_millis)
  [ -s $SPAWNING ] && {
    [[ "$(cat $SPAWNING | awk '{print $2}')" == "completed" ]] && {

       vm_name="$(cat $SPAWNING | awk '{print $1}')"

       # update item record in registry

       remove_line $vm_name $REGISTER

       echo ${vm_name}" new new "$time >> $REGISTER

       # remove $SPAWNING table

       rm -rf $SPAWNING
    } 
  }
  return 0
}

addfor_spawning() {
     local time=$(time_millis)
     [ -s $QUEUE ] && {
      for i in $(cat $QUEUE) ; do
       [[ "$(node_state $i)" == "free" ]] && {
         cp $REGISTER ${REGISTER}.out
         jenkins_cli "disconnect-node" $i
         remove_line $i ${REGISTER}.out
         echo ${i}" new spawning "$time >> ${REGISTER}.out
         mv ${REGISTER}.out $REGISTER
         echo ${i}" progress "$time > $SPAWNING
         rm -rf ${REGISTER}.out
         break
       }
      done
     }
}


renew() {
   # Choose some item from the queue if free
   [ -s $SPAWNING ] || {
     # found no currently processing and include one if any in the QUEUE
     addfor_spawning 
   }
}

node_state() {
   local exit_code=0
   local vm_name=$1
   local tmp="/tmp/JKlmU802_HgIime"
   local script='
     import hudson.FilePath ;
     import hudson.model.Node ;
     import hudson.model.Slave ;
     import jenkins.model.Jenkins ;
     import groovy.time.* ;
     Jenkins jenkins = Jenkins.instance ;
     def jenkinsNodes =jenkins.nodes ;
     for (Node node in jenkinsNodes) 
     {
        if (!node.getComputer().isOffline()) 
        {           
            if(node.getComputer().countBusy()==0)
            {
                println "$node.nodeName free" ;
            }
            else
            {
                println "$node.nodeName busy" ;
            }
        }
        else
        {
            println "$node.nodeName offline" ;
        }
    }
   ' 
   echo $script > $tmp
   cd $UTA
   java -jar jenkins-cli.jar -s $JLINK groovy $tmp  > ${tmp}.out --username jenkins.slave --password $PASSWORD 2>/dev/null
   while read line; do
         [[ "$(echo $line | awk '{print $1}') " == "$vm_name " ]] && {
            echo "$(echo $line | awk '{print $2}')" 
         }
   done < ${tmp}.out
   rm -rf ${tmp}.out
   return 0
}

jenkins_cli() {
   local exit_code=0
   local cmd=$1
   local node=$2
   local pwd_=$(pwd)
   cd $UTA

   java -jar jenkins-cli.jar -s JLINK -noCertificateCheck $cmd $node --username jenkins.slave --password $PASSWORD &>/dev/null || exit_code=$?

   cd $pwd_
   return $exit_code
}

activate_slave() {
   local box_name=$1
   jenkins_cli "connect-node" $box_name || \
   echo "Could not re-connect to $box_name Jenkins node"
   echo
   jenkins_cli "wait-node-online" $box_name && {
      echo "Node $box_name was re-connected and online!"
   } || {
      echo "Could not get $box_name online!"
      return 1
   }
   return 0
}

precauntion() {
   local exit_code=0
   echo "The currently running VM instances:"
   echo
   cd $(dirname $BOXDIR) || return 1 
   vagrant box list
   echo
   read -p "It will remove all existent VM instances above.
   !!There is no recovery option!! Are you sure? [Yy|Nn]:" -n 1 -r

   if [[ ! $REPLY =~ ^[Yy]$ ]]
   then
         echo
         echo "No actions taken!"
         return 1 
   fi
   echo
   read -p "Should we go now? [Yy|Nn]:" -n 1 -r
   if [[ ! $REPLY =~ ^[Yy]$ ]]
   then
         echo
         echo "The operation was terminated!"
         exit_code=1 
   fi
   return $exit_code
}

cleanup() {
   local exit_code=0
   local box_name=$1
   local pid=
   print_message "Cleanup environment from $box_name VM instance!"
   vagrant box list | grep $box_name" "
   [ $? -eq 0 ] && {
      [ -d ${BOXDIR}$box_name ] && {
         cd ${BOXDIR}$box_name || ((exit_code++))
         vagrant box remove --force $box_name || ((exit_code++))
         vagrant destroy --force || ((exit_code++))
      }
      pid=$(ps -ef | grep vagrant-${box_name}_ | grep VBoxHeadless | awk '{print $2}')
      [[ -n $pid ]] && kill -9 $pid  &>/dev/null
      pid=$(ps -ef | grep "tomcat@$box_name java" | awk '{print $2}')
      [[ -n $pid ]] && kill -9 $pid  &>/dev/null
      rm -rf /data/"VirtualBox VMs"/*${box_name}_
   }
   [ -d ${BOXDIR}$box_name ] && {
      cd /
      rm -rf ${BOXDIR}$box_name || ((exit_code++))
   }

   [ -d $HOME/.vagrant.d/boxes/$box_name ] && {
      rm -rf $HOME/.vagrant.d/boxes/$box_name
   }

   mkdir ${BOXDIR}$box_name || ((exit_code++))
   return $exit_code
}

update_vagrant_file() {
   print_message "Update VM instance configuration file with options!"
   local tmp="local"
   [ -f "Vagrantfile" ] && {
      echo "Found Vagrantfile"
      >| $tmp
      while read line; do
        echo "$line" >> $tmp
          [[ "$line" =~ "public_network" ]] && {
             # echo "config.vm.boot.timeout="$BOOT_TIMEOUT >> $tmp
             # echo $REPO_DIR >> $tmp
             echo 'config.vm.network "public_network", ip: "'${ipmap[${BOXNAME}]}'", :bridge => "em1"' >> $tmp
             echo 'config.vm.provider "virtualbox" do |v|' >> $tmp
             echo '   v.memory = "4096"' >> $tmp
             echo '   v.cpus = 2' >> $tmp
             echo 'end' >> $tmp
             echo 'Vagrant::Config.run do |config|' >> $tmp
             echo '    config.ssh.timeout    = 300' >> $tmp
             echo '    config.ssh.max_tries  = 50' >> $tmp
             echo 'end' >> $tmp
             echo 'config.vm.synced_folder "/data/vmmaster/uta/config", "/vagrant_config"' >> $tmp
          }
      done < Vagrantfile
      mv $tmp Vagrantfile || return $?
   }
   return $?
}

create_new_box() {
   print_message "Create and start a new VM instance!"
   local box_name=$1
   local image=$2 
   local exit_code=0
   cd ${BOXDIR}$box_name || ((exit_code++))
   vagrant box add --name $box_name $image || ((exit_code++))
   vagrant init $box_name || ((exit_code++))
   update_vagrant_file || ((exit_code++))
   vagrant up || ((exit_code++))
   return $exit_code  
}

populate_maven_repo() {
   local exit_code=0
   local box_name=$1
   echo "Starting provisioning with maven repository ..."
   echo "It's large repo, wait a few seconds!"
   cp ${CONFDIR}/maven_repository.tar ${BOXDIR}$box_name || ((exit_code++))
   ssh tomcat@${box_name} 'cd /usr/local/tomcat/.m2
   cp /vagrant/maven_repository.tar . 
   tar xf maven_repository.tar
   rm -rf maven_repository.tar' || ((exit_code++))
   rm -rf ${BOXDIR}${box_name}/maven_repository.tar 
   [ $exit_code -eq 0 ] && \
   echo "Succeeded with $box_name maven repository provisioning!"
   return $exit_code
}

set_no_password() {
   print_message "Setup trusted ssh connection!"
   local box_name=$1
   local exit_code=0
   cd ${BOXDIR}$box_name || ((exit_code++))

   # Do not need password submission for the sandbox environment
   vagrant ssh -c 'sudo bash -c "mkdir -p /root/.ssh"'
   vagrant ssh -c 'sudo bash -c "mkdir -p /usr/local/tomcat/.ssh"'
   vagrant ssh -c 'sudo bash -c "chown -R tomcat.tomcat /usr/local/tomcat/.ssh"'
   cat $HOME/.ssh/id_rsa.pub | \
   vagrant ssh -c 'sudo bash -c "cat >> /root/.ssh/authorized_keys"'   
   cat $HOME/.ssh/id_rsa.pub | \
   vagrant ssh -c 'sudo bash -c "cat >> /usr/local/tomcat/.ssh/authorized_keys"'
   ssh-keyscan -H ${ipmap[${BOXNAME}]} >> ~/.ssh/known_hosts
   return $exit_code
} 

set_vm_hostname() {
   print_message "Setup VM instance name!"
   local exit_code=0
   local box_name=$1
   echo "NETWORKING=yes
   HOSTNAME=$box_name" | \
   vagrant ssh -c 'sudo bash -c "cat > /etc/sysconfig/network"'
   (
     for I in ${!ipmap[*]} ; do
       echo ${ipmap[$I]} $I
     done
   ) | vagrant ssh -c 'sudo bash -c "cat >> /etc/hosts"'
   echo $box_name | \
   vagrant ssh -c 'sudo bash -c "cat > /etc/vm.name"' || ((exit_code++))
   vagrant ssh -c 'sudo bash -c "hostname $(cat /etc/vm.name)"' || ((exit_code++))
   local actualname=$(vagrant ssh -c 'sudo bash -c "hostname"') || ((exit_code++))
   local actualname_no_whitespace="$(echo -e "${actualname}" | tr -d '[[:space:]]')"
   echo
   [ "$actualname_no_whitespace" == "$box_name" ] && {
     echo "The VM instance name was set as expected: "$actualname 

     # Include hostname and ip address in the ~/.ssh/known_hosts and avoid duplication
     sed -i '/'"${box_name}"'/d' ~/.ssh/known_hosts || ((exit_code++))
     sed -i '/'"${ipmap[${box_name}]}"'/d' ~/.ssh/known_hosts || ((exit_code++))
     ssh-keyscan -H $box_name >> ~/.ssh/known_hosts # not here 
     ssh-keyscan -H ${ipmap[${box_name}]} >> ~/.ssh/known_hosts || ((exit_code++))
   } || {
     echo "Expected VM name: "$box_name
     echo "Actual VM name : "$actualname_now_whitespace
     echo "Do not match!"
   }
   echo
   [ $exit_code -eq 0 ] && {
     echo "The VM is available for ssh with no password as below"
     echo "ssh tomcat@"${ipmap[${box_name}]}" or ssh tomcat@"$box_name
     echo
     echo "The VM instance configuration directory is: "${BOXDIR}$box_name
     echo "This location is available directly from VM /vagrant mount point."
   }
   return $exit_code 
}

set_timezone() {
   print_message "Setup timezone!"
   local box_name=$1
   local exit_code=0
   ssh root@${box_name} 'rm -rf /etc/localtime ;
   ln -s /usr/share/zoneinfo/UTC /etc/localtime' || ((exit_code++))

   return $exit_code
}

setup_vnc_password() {
   print_message "Setup vnc connection password!"
   local box_name=$1
   local exit_code=0

   ssh tomcat@${box_name} '/vagrant_config/set_vnc.sh' || ((exit_code++))

   return $exit_code
}

launch_grid_node() {
   print_message "Launch selenium grid node"
   local box_name=$1
   local exit_code=0
   cd ${BOXDIR}${box_name} || ((exit_code++))
   cp ${CONFDIR}/selenium-server-standalone-2.46.0.jar . || ((exit_code++))
   cp ${CONFDIR}/nodeconfig.json . || ((exit_cod++))
   cp ${CONFDIR}/run_selenium.sh . || ((exit_code++))
   cp ${CONFDIR}/grid . || ((exit_code++))
   ssh tomcat@${box_name} 'cp /vagrant/selenium-server-standalone-2.46.0.jar .' \
      || ((exit_code++))
   ssh tomcat@${box_name} 'cp /vagrant/nodeconfig.json .' || ((exit_code++))
   ssh tomcat@${box_name} 'cp /vagrant/run_selenium.sh .' || ((exit_code++))
   ssh root@${box_name} 'cp /vagrant/grid /etc/init.d/' || ((exit_code++))
   ssh root@${box_name} 'ln -s /etc/init.d/grid /etc/rc3.d/S60seleniumgrid' \
      || ((exit_code++))
   ssh root@${box_name} 'ln -s /etc/init.d/grid /etc/rc3.d/K20selenimgrid' \
      || ((exit_code++))
   ssh root@${box_name} 'cd /etc/init.d/ ; ./grid start' || ((exit_code++))
   rm -rf selenium-server-standalone-2.46.0.jar *.json *.sh grid 
   return $exit_code
}

while getopts ":d:i:hbsm:n:o:" opt; do
   case $opt in
      b) echo "Background process"
         BACKGROUND="yes"
         echo $DAEMON_PID > $_PID
         ;;
      d) echo "Virtual machine directory: "$OPTARG
         BOXDIR=${OPTARG}"/"
         ;;
      i) echo "Virtual machine image name: "$OPTARG
         IMAGE_URL=$OPTARG
         ;;
      h) help
         exit 0
         ;;
      m) echo "Mode: "$OPTARG
         MODE=$OPTARG
         ;;
      n) echo "Virtual machine name: "$OPTARG
         BOXNAME=$OPTARG
         ;;
      o) echo "OS type: "$OPTARG
         OS=$OPTARG
         ;;
      s) echo "Selenium image"
         SELENIUM="yes"
         ;;
      :) echo "Option - $OPTARG requires an argument." >&2
         ;;
      *) echo "Invalid option: "$OPTARG >&2
         usage
         exit 1
         ;;
   esac
done

if [ "${BACKGROUND}" != "yes" ] ; then
   [ $((${OPTIND}-1)) -eq 0 ] && {
      echo "No options were passed."
      exit 1
   }
fi

# The only mandatory opion is "-n" for a sigle OS type, currently "centos"
# [ -z $BOXNAME ] && BOXNAME=$OS 

[ -d ${BOXDIR}$BOXNAME ] && {
   cd ${BOXDIR}$BOXNAME
}

if [ "$MODE" == "cleanup" ]; then
   for i in $BOXNAME ; do
       cleanup $i || ((ERROR++))
   done 
elif [ "$MODE" == "remove" ] ; then
   # It is not safe operation, use it with cauntion   
   precauntion || exit 0
   echo
   echo "The removal will start in 10 seconds!"
   sleep 15 # but, lets wait longer 
   ${UTA}/vmanager -m list
   list_active=$(${UTA}/vmanager -m list | \
      grep virtualbox | awk '{print $1}'" ")
   for i in $list_active ; do
      ${UTA}/vmanager -m cleanup -n $i
   done
   readonly pids=$(ps -ef|grep VBoxHeadless|awk '{print $2}')
   echo "Removing all currently running VBox processes: "$pids
   for i in $pids ; do
      kill -9 $i 2>$DEVNULL 
   done
   rm -rf /tmp/d2015* 
   rm -rf /tmp/vagrant*
elif [ "$MODE" == "setup" ] ; then
   cleanup $BOXNAME || ((ERROR++))
   if [ -z $IMAGE_URL ] ; then
      # Uncomment for multiple OS types, currently is just "centos"
      # [ "$OS" == "centos" ] && {
         if [ "${SELENIUM}" == "yes" ] ; then 
            create_new_box $BOXNAME ${BASEURL}/$CENTOS_IMG_SELENIUM || ((ERROR++))
         else 
            create_new_box $BOXNAME ${BASEURL}/$CENTOS_IMG || ((ERROR++))
         fi 
         set_no_password $BOXNAME || ((ERROR++))
         set_timezone $BOXNAME || ((ERROR++)) 
         set_vm_hostname $BOXNAME || {
            echo "Check why could not set VM host name!"
         } && {
            echo
            if [ "${SELENIUM}" == "yes" ] ; then 
               echo "Selenium"
               # else 
               #   populate_maven_repo $BOXNAME || \
               #   echo "Check why could not populate maven repo!"  
            fi 
            # activate_slave $BOXNAME || \
            # echo "Failed activate Jenkins slave "$BOXNAME
         }
         setup_vnc_password $BOXNAME || ((ERROR++))
         if [ "${SELENIUM}" == "yes" ] ; then 
           launch_grid_node $BOXNAME || ((ERROR++))
         fi 
         if [ "${SELENIUM}" == "yes" ] ; then
           ssh tomcat@$BOXNAME "rm -rf /var/log/vnc_xvfb.log ; /usr/local/tomcat/run_vnc.sh"
         fi
      # } 
   else
      # In case of necessity to specify the image source 
      # create_new_box $BOXNAME $IMAGE_URL || ((ERROR++))
      echo "Is not at this stage!"
   fi
elif [ "$MODE" == "halt" ] ; then
   print_message "Stop virtual machine!"
   vagrant halt || ((ERROR++))
elif [ "$MODE" == "up" ] ; then
   print_message "Start virtual machine!"
   vagrant up || ((ERROR++))
   activate_slave $BOXNAME || echo "Failed activate Jenkins slave "$BOXNAME
elif [ "$MODE" == "reload" ] ; then
   print_message "Reload virtual machine configuration!"
   vagrant reload || ((ERROR++))
   activate_slave $BOXNAME || echo "Failed activate Jenkins slave "$BOXNAME
elif [ "$MODE" == "status" ] ; then
   [ -z "$BOXNAME" ] && {
      list_active=$(${UTA}/vmanager -m list | \
         grep virtualbox | awk '{print $1}')
   } || {
      list_active=$BOXNAME
   } 
   for i in $list_active ; do
      print_message "Show status of virtual machine "$i" !"
      cd "/data/vmmaster/vagrant-"$i
      vagrant status || ((ERROR++))
   done 
elif [ "$MODE" == "list" ] ; then
   print_message "Show all activated virtual machines!"
   cd $(dirname $BOXDIR) || ((ERROR++))
   vagrant box list
elif [ "$MODE" == stop ] ; then
   print_message "Shutting down currently running virtual machines.." 
   list=""
   >| ${CONFDIR}/../state/startstop.conf
   ${UTA}/vmanager -m list
   list_active=$(${UTA}/vmanager -m list | \
      grep virtualbox | awk '{print $1}')
   for i in $list_active ; do
      ${UTA}/vmanager -m status -n $i \
         | grep running && echo $i >> ${CONFDIR}/../state/startstop.conf 
      echo "Show VM: "$i
   done
   echo "Show all VMs: "$(cat ${CONFDIR}/../state/startstop.conf)
   for i in $(cat ${CONFDIR}/../state/startstop.conf) ; do
      ${UTA}/vmanager -m halt -n $i
   done
   print_message "Shutted down virtual machines: "$(cat ${CONFDIR}/../state/startstop.conf)
elif [ "$MODE" == start ] ; then
   print_message "Starting up all previously running virtual machines.."
   list=$(cat ${CONFDIR}/../state/startstop.conf)
   for i in $list ; do
       ${UTA}/vmanager -m up -n $i
   done
   print_message "Started up all previously running VMs: "$list 
else
   if [ "${BACKGROUND}" == "yes" ] ; then
      vms_initial
      for (( ; ; )) ; do
          check_all_vms
          update_running
          update_queue
          renew 
          check_status
          sleep 10           
      done
   else   
      usage 
      ((ERROR++))
   fi
fi
print_message "Completed!"
[ -z $ERROR ] && exit 0 || exit $ERROR
