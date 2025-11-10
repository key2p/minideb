#!/bin/sh
# 优化系统配置

do_optimize() {
    local root_path=$1
    if [ ! -d "$root_path" ]; then
        echo "Error: Invalid root path '$root_path'." >&2
        return 1        
    fi

    # "1Gxxxxxx.z"
    sed -i 's/root:\*::0/root:$5$w.JKSz9Y5C7OR5DF$q5VtSLYI3OZPXkBLi9QnDrPxfHeo9Am3Tzpt7CNr.T9::0/g' "${root_path}/etc/shadow"

    # 优化内核参数
    cat <<EOF > "${root_path}/etc/sysctl.conf"
# 优化内核参数
net.core.netdev_budget = 599
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_orphans = 32768
net.ipv4.ip_local_port_range = 10000 64000
net.ipv4.ip_forward = 1

net.ipv4.ip_default_ttl=128
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_mtu_probing = 1

# https://blog.cloudflare.com/optimizing-tcp-for-high-throughput-and-low-latency/
net.ipv4.tcp_rmem=8192 262144 33554432
net.ipv4.tcp_wmem=4096 16384 16777216
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_collapse_max_bytes = 6291456
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_moderate_rcvbuf = 1

# https://blog.cloudflare.com/unbounded-memory-usage-by-tcp-for-receive-buffers-and-how-we-fixed-it/
net.ipv4.tcp_shrink_window = 1

net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout = 13
net.ipv4.tcp_max_tw_buckets=65535
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_keepalive_time = 180

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 启用BBR
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

net.nf_conntrack_max=1000000

# https://zhuanlan.zhihu.com/p/109336249 减少 swap 使用
# https://aws.amazon.com/cn/blogs/china/optimization-practice-of-achieving-1-million-json-api-requests-second-with-4-vcpu-instances/
# https://talawah.io/blog/extreme-http-performance-tuning-one-point-two-million/
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=2
vm.vfs_cache_pressure = 68

# 增加系统文件描述符限制
fs.file-max=2147483647
fs.inotify.max_user_instances=8192

EOF

    # 优化系统资源限制
    mkdir -p "${root_path}/etc/security"
    cat <<EOF > "${root_path}/etc/security/limits.conf"
* soft nofile 65536
* hard nofile 131072
* soft nproc 65536
* hard nproc 131072
root soft nofile 131072
root hard nofile 262144
root soft noproc 65535
root hard noproc 131072
EOF

    # 配置时钟同步
    cat <<EOF > "${root_path}/etc/ntp.conf"
server time.apple.com
server time.cloudflare.com
server ntp.aliyun.com
server 0.pool.ntp.org
server cn.ntp.org.cn
EOF

    # 配置ssh密钥
    mkdir -p "${root_path}/root/.ssh"

    [ -f "${root_path}/root/.ssh/authorized_keys" ] &&sed -i "/zpod_priv/d" "${root_path}/root/.ssh/authorized_keys" || true
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAax55Ogt7DuDho0WK75CDHL8Uuflaj1uRXt60/Q//39 zpod_priv@host" >>"${root_path}/root/.ssh/authorized_keys"

    chmod 0600      "${root_path}/root/.ssh/authorized_keys"
    chmod 0700 -R   "${root_path}/root/.ssh"

    #没有openssh,用的dropbear启用密钥验证
    #mkdir -p "${root_path}/etc/ssh"
    #sed -i '/RSAAuthentication/d'       "${root_path}/etc/ssh/sshd_config"  || true
    #sed -i '/PubkeyAuthentication/d'    "${root_path}/etc/ssh/sshd_config"  || true
    #sed -i '/PasswordAuthentication/d'  "${root_path}/etc/ssh/sshd_config"  || true
    #sed -i '/PermitRootLogin/d'         "${root_path}/etc/ssh/sshd_config"  || true
    #echo "PasswordAuthentication no" >> "${root_path}/etc/ssh/sshd_config"
    #echo "PubkeyAuthentication yes"  >> "${root_path}/etc/ssh/sshd_config"
    #echo "PermitRootLogin yes"       >> "${root_path}/etc/ssh/sshd_config"

    echo zpod_host> "${root_path}/etc/hostname"
    
    #审计
    sed -i '/LOGIN_IP/d'        "${root_path}/etc/profile"  || true
    sed -i '/PROMPT_COMMAND/d'  "${root_path}/etc/profile"  || true
    sed -i '/HISTTIMEFORMAT/d'  "${root_path}/etc/profile"  || true

    echo "alias docker=podman" >> "${root_path}/etc/profile"

    echo "LOGIN_IP=\$(who am i | awk '{print \$NF}')" >> "${root_path}/etc/profile"
    echo export HISTTIMEFORMAT=\"%F %T \`whoami\` \" >> "${root_path}/etc/profile"
    echo export "PROMPT_COMMAND='RETRN_VAL=\$?;logger -p local6.debug \"[\$(whoami)@\$SSH_USER\$LOGIN_IP: \`pwd\`] [\$\$]: \$(history 1 | sed \"s/^[ ]*[0-9]\\+[ ]*//\" ) [\$RETRN_VAL]\"'" >> "${root_path}/etc/profile"
  
    echo local6.*  /var/log/commands.log >> "${root_path}/etc/syslog.conf"

    # 只保留2个tty1, tty2
    sed -i '/tty3/d'        "${root_path}/etc/inittab"  || true
    sed -i '/tty4/d'        "${root_path}/etc/inittab"  || true
    sed -i '/tty5/d'        "${root_path}/etc/inittab"  || true
    sed -i '/tty6/d'        "${root_path}/etc/inittab"  || true

}