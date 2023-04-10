# Init script
sudo mv /etc/ntp.conf /etc/ntp.conf- 
sudo ln -s /oradata/.secrets/common_os_pwdfile.enc /run/secrets/common_os_pwdfile.enc
sudo ln -s /oradata/.secrets/pwd.key /run/secrets/pwd.key
sudo mount --bind /hostproc/net/core /proc/sys/net/core
sudo echo 950000 > /sys/fs/cgroup/cpu/system.slice/cpu.rt_runtime_us
sudo sysctl kernel.sched_rt_runtime_us=-1
sudo sed -i 's/134217728$/8388608/'  /etc/security/limits.conf
sudo yum -y install chrony
sudo systemctl start chronyd
