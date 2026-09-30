#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach_time.h>
// usage: rusage SECONDS pid...
int main(int argc,char**argv){
  int secs=atoi(argv[1]); int n=argc-2;
  struct rusage_info_v6 a[16],b[16];
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  for(int i=0;i<n;i++) if(proc_pid_rusage(atoi(argv[i+2]),RUSAGE_INFO_V6,(rusage_info_t*)&a[i])){perror("rusage");return 1;}
  sleep(secs);
  for(int i=0;i<n;i++) proc_pid_rusage(atoi(argv[i+2]),RUSAGE_INFO_V6,(rusage_info_t*)&b[i]);
  printf("%-7s %10s %10s %10s %10s %10s %10s\n","pid","cpu_ms","uJ_billed","uJ/s","intr_wk","idle_wk","rss_MB");
  for(int i=0;i<n;i++){
    double cpu=((b[i].ri_user_time-a[i].ri_user_time)+(b[i].ri_system_time-a[i].ri_system_time))*(double)tb.numer/tb.denom/1e6;
    double e=(b[i].ri_billed_energy-a[i].ri_billed_energy)/1e3;
    printf("%-7s %10.1f %10.0f %10.1f %10llu %10llu %10.1f\n",argv[i+2],cpu,e,e/secs,
      b[i].ri_interrupt_wkups-a[i].ri_interrupt_wkups,b[i].ri_pkg_idle_wkups-a[i].ri_pkg_idle_wkups,b[i].ri_resident_size/1048576.0);
  }
}
