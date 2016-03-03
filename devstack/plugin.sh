###################
### Cinder
###################
function configure_cinder_backend_sofs {
    local be_name=$1
    iniset $CINDER_CONF $be_name volume_backend_name $be_name
    iniset $CINDER_CONF $be_name volume_driver "cinder.volume.drivers.scality.ScalityDriver"
    iniset $CINDER_CONF $be_name scality_sofs_config $SCALITY_SOFS_CONFIG
    iniset $CINDER_CONF $be_name scality_sofs_mount_point $SCALITY_SOFS_MOUNT_POINT
}

function init_cinder_backend_sofs {
    if [[ ! -d $SCALITY_SOFS_MOUNT_POINT ]]; then
        sudo mkdir $SCALITY_SOFS_MOUNT_POINT
    fi
    sudo chmod +x $SCALITY_SOFS_MOUNT_POINT

    # We need to make sure we have a writable 'cinder' dir in SOFS
    local sfused_mount_point
    sfused_mount_point=$(mount | grep "/dev/fuse" | grep -v scality | grep -v sproxyd | cut -d" " -f 3 || true)
    if [[ -z "${sfused_mount_point}" ]]; then
        if ! sudo mount -t sofs $SCALITY_SOFS_CONFIG $SCALITY_SOFS_MOUNT_POINT; then
            echo "Unable to mount the SOFS filesystem! Please check the configuration in $SCALITY_SOFS_CONFIG and the syslog."; exit 1
        fi
        sfused_mount_point=$SCALITY_SOFS_MOUNT_POINT
    fi
    if [[ ! -d $sfused_mount_point/cinder ]]; then
        sudo mkdir $sfused_mount_point/cinder
    fi
    sudo chown $STACK_USER $sfused_mount_point/cinder

    sudo umount $sfused_mount_point
    if [[ -x "$(which sfused 2>/dev/null)" ]]; then
        sudo service scality-sfused stop
    fi
}



###################
### Glance
###################
if is_service_enabled g-api && [[ "$USE_SCALITY_FOR_GLANCE" == "True" ]]; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        sudo pip install https://github.com/scality/scality-sproxyd-client/archive/master.tar.gz
        sudo pip install https://github.com/scality/scality-glance-store/archive/master.tar.gz
    fi
fi



###################
### Nova
###################
if is_service_enabled nova; then
    if [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        if [[ -n "$CINDER_ENABLED_BACKENDS" ]] && [[ ,${CINDER_ENABLED_BACKENDS} =~ ,sofs: ]]; then
            iniset $NOVA_CONF libvirt scality_sofs_config $SCALITY_SOFS_CONFIG
            iniset $NOVA_CONF libvirt scality_sofs_mount_point $SCALITY_SOFS_MOUNT_POINT
        fi
    fi
fi



###################
### Swift
###################
if is_service_enabled swift && [[ $USE_SCALITY_FOR_SWIFT == "True" ]]; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        sudo pip install https://github.com/scality/scality-sproxyd-client/archive/master.tar.gz
        sudo pip install https://github.com/scality/ScalitySproxydSwift/archive/master.tar.gz
    fi
    if [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        for node_number in ${SWIFT_REPLICAS_SEQ}; do
            my_swift_node_config=${SWIFT_CONF_DIR}/object-server/${node_number}.conf
            iniset ${my_swift_node_config} app:object-server use egg:swift_scality_backend#sproxyd_object
            iniset ${my_swift_node_config} app:object-server sproxyd_endpoints $SCALITY_SPROXYD_ENDPOINTS
        done
    fi
fi



###################
### Manila
###################
if is_service_enabled manila && [[ $USE_SCALITY_FOR_MANILA == "True" ]]; then

    ### Stack ###
    if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # XXX In order to avoid constant rebase of upstream, do a dirty copy
        git clone -b ${MANILA_BRANCH:-master} ${MANILA_REPO} /tmp/scality-manila
        cp -r /tmp/scality-manila/manila/share/drivers/scality \
            /opt/stack/manila/manila/share/drivers

        source ${dir}/environment/netdef

        # Manila general section
        export MANILA_PATH_TO_PUBLIC_KEY="${MANAGEMENT_KEY_PATH}.pub"
        export MANILA_PATH_TO_PRIVATE_KEY=${MANAGEMENT_KEY_PATH}
        export MANILA_ENABLED_BACKENDS="ring"
        export MANILA_DEFAULT_SHARE_TYPE="scality"
        export MANILA_DEFAULT_SHARE_TYPE_EXTRA_SPECS="share_backend_name=scality_ring snapshot_support=False"

        # Manila ring section
        export MANILA_OPTGROUP_ring_driver_handles_share_servers=False
        export MANILA_OPTGROUP_ring_share_backend_name=scality_ring
        export MANILA_OPTGROUP_ring_share_driver=manila.share.drivers.scality.driver.ScalityShareDriver
        export MANILA_OPTGROUP_ring_nfs_export_ip=${RINGNET_NFS_EXPORT_IP}
        export MANILA_OPTGROUP_ring_nfs_management_host=${NFS_CONNECTOR_HOST}
        export MANILA_OPTGROUP_ring_smb_export_ip=${RINGNET_SMB_EXPORT_IP}
        export MANILA_OPTGROUP_ring_smb_management_host=${CIFS_CONNECTOR_HOST}
        export MANILA_OPTGROUP_ring_smb_export_root=${SMB_EXPORT_ROOT:-/ring/fs}
        export MANILA_OPTGROUP_ring_management_user=${MANAGEMENT_USER}
        export MANILA_OPTGROUP_ring_ssh_key_path=${MANAGEMENT_KEY_PATH}
    fi

    # install phase: Setup bridge
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        sudo ovs-vsctl add-br br-ringnet
    fi

	# post-config phase: Configure neutron
    if [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks physnet
        iniset /etc/neutron/plugins/ml2/ml2_conf.ini ovs bridge_mappings physnet:br-ringnet
    fi

	# extra phase: Create neutron network for tenant use
    if [[ "$1" == "stack" && "$2" == "extra" ]]; then
        source ${dir}/environment/netdef
        neutron net-create ringnet --shared --provider:network_type flat --provider:physical_network physnet
        neutron subnet-create ringnet --allocation-pool ${TENANTS_POOL} --name ringsubnet ${TENANTS_NET} \
                                --enable-dhcp --host-route destination=${RINGNET_NFS},nexthop=${TENANT_NFS_GW} \
                                --host-route destination=${RINGNET_SMB},nexthop=${TENANT_SMB_GW}

        # Add IP to provider network bridge
        sudo ip addr add ${TENANTS_BR} dev br-ringnet

        # Configure tempest
        TEMPEST_DIR=/opt/stack/tempest
        if [ -d ${TEMPEST_DIR} ]; then
            iniset ${TEMPEST_DIR}/etc/tempest.conf service_available manila True
            iniset ${TEMPEST_DIR}/etc/tempest.conf cli enabled True
            iniset ${TEMPEST_DIR}/etc/tempest.conf share multitenancy_enabled False
            iniset ${TEMPEST_DIR}/etc/tempest.conf share run_extend_tests False
            iniset ${TEMPEST_DIR}/etc/tempest.conf share run_shrink_tests False
            iniset ${TEMPEST_DIR}/etc/tempest.conf share run_snapshot_tests False
            iniset ${TEMPEST_DIR}/etc/tempest.conf share run_consistency_group_tests False

            # Remove the following line when https://review.openstack.org/#/c/263664 is reverted
            # and https://bugs.launchpad.net/manila/+bug/1531049 is fixed
            ADMIN_TENANT_NAME=${ADMIN_TENANT_NAME:-"admin"}
            ADMIN_PASSWORD=${ADMIN_PASSWORD:-"secretadmin"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf auth admin_username ${ADMIN_USERNAME:-"admin"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf auth admin_password $ADMIN_PASSWORD
            iniset ${TEMPEST_DIR}/etc/tempest.conf auth admin_tenant_name $ADMIN_TENANT_NAME
            iniset ${TEMPEST_DIR}/etc/tempest.conf auth admin_domain_name ${ADMIN_DOMAIN_NAME:-"Default"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity username ${TEMPEST_USERNAME:-"demo"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity password $ADMIN_PASSWORD
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity tenant_name ${TEMPEST_TENANT_NAME:-"demo"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity alt_username ${ALT_USERNAME:-"alt_demo"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity alt_password $ADMIN_PASSWORD
            iniset ${TEMPEST_DIR}/etc/tempest.conf identity alt_tenant_name ${ALT_TENANT_NAME:-"alt_demo"}
            iniset ${TEMPEST_DIR}/etc/tempest.conf validation ip_version_for_ssh 4
            iniset ${TEMPEST_DIR}/etc/tempest.conf validation ssh_timeout $BUILD_TIMEOUT
            iniset ${TEMPEST_DIR}/etc/tempest.conf validation network_for_ssh ${PRIVATE_NETWORK_NAME:-"private"}
        else
            echo "Unable to configure tempest for the Scality Manila driver"
        fi
    fi

    if [[ "$1" == "unstack" ]]; then
        sudo ovs-vsctl del-br br-ringnet
    fi

fi
