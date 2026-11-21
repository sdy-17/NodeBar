#include <libproc.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

static inline unsigned long long node_identity(int pid) {
    struct proc_bsdinfo b = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b) || b.pbi_uid != getuid()) return 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return 0;
    const char *name = strrchr(path, '/');
    if (!name || (strcmp(name+1, "node") && strcmp(name+1, "nodejs"))) return 0;
    return b.pbi_start_tvsec * 1000000ull + b.pbi_start_tvusec;
}
static inline char *process_cwd(int pid) {
    struct proc_vnodepathinfo v;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof(v)) != sizeof(v)) return NULL;
    return strdup(v.pvi_cdir.vip_path);
}

static inline int socket_accepts_ipv4(int pid, int fd) {
    struct socket_fdinfo info = {0};
    if (proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.psi.soi_kind == SOCKINFO_TCP &&
        (info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag & INI_IPV4) != 0;
}
