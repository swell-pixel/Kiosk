//
//  Uptime.h
//

time_t uptime() //iOS system uptime that does not pause when asleep
{
    struct timeval boottime;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    size_t size = sizeof(boottime);
    time_t uptime = -1;
    
    if (sysctl(mib, 2, &boottime, &size, NULL, 0) != -1 &&
        boottime.tv_sec != 0)
    {
        time_t now;
        time(&now);
        uptime = now - boottime.tv_sec;
    }
    return uptime;
}
