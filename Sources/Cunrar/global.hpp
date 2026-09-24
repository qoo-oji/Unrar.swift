#ifndef _RAR_GLOBAL_
#define _RAR_GLOBAL_

#ifdef INCLUDEGLOBAL
  #define EXTVAR
#else
  #define EXTVAR extern
#endif

// [qoo-oji fork] One error state per thread. unrar keeps the result of the current operation here and the
// DLL returns it (RARReadHeaderEx / RARProcessFile end with ErrHandler.GetErrorCode(), RAROpenArchive calls
// ErrHandler.Clean()). With a single process-wide object, an archive failing on one thread (a CRC error)
// made a successful operation on another thread report that error. A DLL operation runs entirely on the
// calling thread here (RAR_SMP is only defined for Windows), so per-thread state is the operation's own.
EXTVAR thread_local ErrorHandler ErrHandler;



#endif
