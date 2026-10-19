// src/init.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

static void mount_fs(const char *source, const char *target, const char *type, unsigned long flags, const void *data) {
    mkdir(target, 0755);
    if (mount(source, target, type, flags, data) < 0 && errno != EBUSY) {
        fprintf(stderr, "[init] Failed to mount %s: %s\n", target, strerror(errno));
    }
}

static pid_t spawn(char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        execvp(argv[0], argv);
        perror("[init] execvp failed");
        _exit(127);
    }
    return pid;
}

int main(void) {
    // Ensure we are running as PID 1
    if (getpid() != 1) {
        fprintf(stderr, "Must be run as PID 1\n");
        return 1;
    }

    // 1. Mount core kernel virtual filesystems
    mount_fs("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    mount_fs("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "gid=5,mode=620");
    mount_fs("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755,size=16M");
    mount_fs("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777,size=64M");

    // 2. Configure hostname and kernel memory overcommit/panic behavior
    sethostname("nanonode", 8);
    int fd = open("/proc/sys/kernel/panic", O_WRONLY);
    if (fd >= 0) { write(fd, "10\n", 3); close(fd); }

    printf("\n========================================\n");
    printf("  NanoNode Server OS Booted (PID 1)     \n");
    printf("========================================\n");

    // 3. Bring up networking and SSH via helper script
    char *net_cmd[] = {"/sbin/net-up", NULL};
    pid_t net_pid = spawn(net_cmd);
    waitpid(net_pid, NULL, 0);

    // 4. Spawn Dropbear SSH daemon (-R generates hostkeys if missing, -F foreground, -s disables password login)
    char *ssh_cmd[] = {"/usr/sbin/dropbear", "-R", "-F", "-s", "-p", "22", NULL};
    pid_t ssh_pid = spawn(ssh_cmd);

    // 5. Spawn a local rescue shell on tty1 in case physical debugging is needed
    char *tty_cmd[] = {"/bin/sh", NULL};
    pid_t tty_pid = spawn(tty_cmd);

    // 6. PID 1 Supervisor & Zombie Process Reaper Loop
    for (;;) {
        int status;
        pid_t reaped = waitpid(-1, &status, 0);
        if (reaped < 0) continue;

        // Respawn SSH daemon immediately if it ever crashes
        if (reaped == ssh_pid) {
            printf("[init] Dropbear exited, respawning...\n");
            sleep(1);
            ssh_pid = spawn(ssh_cmd);
        } else if (reaped == tty_pid) {
            tty_pid = spawn(tty_cmd);
        }
    }
    return 0;
}