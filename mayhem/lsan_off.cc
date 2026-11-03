// LeakSanitizer is disabled at build time for every fuzz binary (SPEC §6.2 item 17 / rules/c.md).
extern "C" int __lsan_is_turned_off() { return 1; }
