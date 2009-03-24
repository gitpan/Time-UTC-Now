#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define TAI_EPOCH_MJD 36204

#define UNIX_EPOCH_MJD 40587
#define UNIX_EPOCH_DAYNO (UNIX_EPOCH_MJD - TAI_EPOCH_MJD)

#ifdef QHAVE_NTP_ADJTIME
/*
 * ** use of ntp_adjtime() **
 *
 * The kernel variables returned by ntp_adjtime() and ntp_gettime()
 * don't necessarily behave the way they're supposed to.  The
 * variables we're interested in are:
 *
 * ntv.time      Unix time number, as seconds plus microseconds
 * leap_state    leap second state
 * ntv.maxerror  alleged maximum possible error, in microseconds
 * tx.offset     offset being applied to clock, in microsecods
 * tx.tolerance  possible inaccuracy of clock rate, in scaled ppm
 *
 * The leap second state can be:
 *   TIME_OK:  normal, no leap second nearby
 *   TIME_INS: leap second is to be inserted at the end of this day
 *   TIME_DEL: leap second is to be deleted at the end of this day
 *   TIME_OOP: the current second is a leap second being inserted
 *   TIME_WAIT: leap occured in the recent past
 *
 * The state goes from TIME_OK to TIME_{INS,DEL} some time during
 * the UTC day that will have a leap at the end.  This happens by
 * the STA_{INS,DEL} flags being set from user space.  After the
 * leap the TIME_WAIT state persists until the STA_{INS,DEL} flags
 * are cleared.
 *
 * Behaviour across midnight is nominally thus:
 *
 *   398 TIME_DEL     398 TIME_OK      398 TIME_INS
 *   400 TIME_WAIT    399 TIME_OK      399 TIME_INS
 *   401 TIME_WAIT    400 TIME_OK      399 TIME_OOP
 *   402 TIME_WAIT    401 TIME_OK      400 TIME_WAIT
 *
 * So to decode that all we have to do is recognise state TIME_OOP
 * as indicating 86400 s of the current day and otherwise split up
 * ntv.time.tv_sec conventionally.  We wouldn't need to recognise
 * the other leap second states.  Note that the second *before*
 * midnight is being repeated in the Unix time number, which is
 * contrary to POSIX, but this is standard behaviour for
 * ntp_adjtime() as defined by [KERN-MODEL].
 *
 * What actually happens in Linux (as of 2.4.19) is rather messier.
 * The leap second processing does not occur atomically along with
 * the rollover of the second.  There's a delay (5 ms on my machine)
 * after the seconds counter increments before the leap second state
 * changes and the counter gets warped.  So we see this:
 *
 *   398.5 TIME_DEL     398.5 TIME_OK      398.5 TIME_INS
 *   399.0 TIME_DEL     399.0 TIME_OK      399.0 TIME_INS
 *   400.5 TIME_WAIT    399.5 TIME_OK      399.5 TIME_INS
 *   401.0 TIME_WAIT    400.0 TIME_OK      400.0 TIME_INS
 *   401.5 TIME_WAIT    400.5 TIME_OK      399.5 TIME_OOP
 *   402.0 TIME_WAIT    401.0 TIME_OK      400.0 TIME_OOP
 *   402.5 TIME_WAIT    401.5 TIME_OK      400.5 TIME_WAIT
 *
 * So the time that is deleted or repeated on the Unix time number
 * is not exactly an integer-delimited second, but is some second
 * encompassing midnight, roughly [399.005, 400.005].  Naive
 * decoding of the seconds counter gives non-existent times
 * when a second is deleted, and jumps around when a second is
 * inserted.  [KERN-MODEL] admits this possibility.
 *
 * Fortunately the leap second state change *does* occur atomically
 * with the second warp.  It is therefore possible to fix up the
 * values returned by the kernel by an understanding of all the
 * states of the leap second machine.  If the kernel does the job
 * properly (in a hypothetical future version) then the extra fixup
 * code will never execute and everything will still work.
 *
 * There's another complication.  If the clock is in an
 * "unsynchronised" condition then ntp_adjtime() gives us the
 * error value TIME_ERROR in leap_state, instead of the leap
 * second state. The leap second state machine still operates
 * in this condition (at least on Linux), we just can't see
 * its state variable.  Annoyingly, we could have picked up the
 * unsynchronised condition (which we do care about) from the
 * STA_UNSYNCH status flag instead, so the leap state is being
 * gratuitously squashed.  The upshot is that we can't decode
 * properly around leap seconds if the clock is unsynchronised,
 * but that's not a disaster because we're not claiming accuracy
 * in that case anyway.
 *
 * The possible error in the clock value is supposedly in
 * ntv.maxerror.  However, this has a couple of problems.  It is
 * updated in chunks at intervals of 1 s, rather than keeping
 * step with the time, so it might not reflect the possible
 * inaccuracy developed in the last second.  We add on an
 * adjustment based on tx.tolerance to fix this.
 *
 * Also, according to my understanding of the ntpd source, it seems
 * that ntv.maxerror is based on the time that the clock would show
 * after the current offset adjustment is completed, not what it
 * currently shows.  (ntpd seems to completely ignore the fact that
 * the offset adjustment is not instantaneous!)  In principle we
 * could apply the offset ourselves to get a more precise time, but
 * this causes non-monotonicity even in a synchronised clock (and
 * also more leap second joy if the offset is negative).  Therefore
 * we just treat the pending offset as another source of error.
 *
 * An additional microsecond is added to the error bound to
 * account for possible rounding down of the time value in the
 * kernel.
 *
 * reference:
 * [KERN-MODEL] David L. Mills, "A Kernel Model for Precision
 * Timekeeping", 31 January 1996, <ftp://ftp.udel.edu/pub/people/
 * mills/memos/memo96b.ps>.
 */

# include <sys/timex.h>

/* there are several names for the error state returned by ntp_adjtime() */
# ifndef TIME_ERROR
#  ifdef TIME_ERR
#   define TIME_ERROR TIME_ERR
#  elif defined(TIME_BAD)
#   define TIME_ERROR TIME_BAD
#  endif
# endif

/* this might not be in the user-space version of the header */
# ifndef SHIFT_USEC
#  define SHIFT_USEC 16
# endif

/* time structures may be struct timeval or struct timespec */
# ifdef QHAVE_STRUCT_TIMEX_TIME_TV_NSEC
#  define TIMEX_SUBSEC tv_nsec
# else
#  define TIMEX_SUBSEC tv_usec
# endif
# ifdef QHAVE_STRUCT_NTPTIMEVAL_TIME_TV_NSEC
#  define NTPTIMEVAL_SUBSEC tv_nsec
# else
#  define NTPTIMEVAL_SUBSEC tv_usec
# endif

/* this state flag might not exist */
# ifndef STA_NANO
#  define STA_NANO 0
# endif

static int try_ntpadjtime(int demanding_accuracy)
{
	dSP;
	int state;
	struct timex tx;
	long dayno, secs;
# ifdef QHAVE_STRUCT_TIMEX_TIME
#  define ntv tx
#  define NTV_SUBSEC TIMEX_SUBSEC
# else /* !QHAVE_STRUCT_TIMEX_TIME */
	struct ntptimeval ntv;
#  define NTV_SUBSEC NTPTIMEVAL_SUBSEC
	struct timex txx;
# endif /* !QHAVE_STRUCT_TIMEX_TIME */
# if defined(QHAVE_STRUCT_TIMEX_TIME) ? defined(QHAVE_STRUCT_TIMEX_TIME_STATE) : defined(QHAVE_STRUCT_NTPTIMEVAL_TIME_STATE)
#  define leap_state ntv.time_state
# else
#  define leap_state state
# endif
#ifdef QHAVE_STRUCT_TIMEX_TIME
	Zero(&tx, 1, struct timex);
	state = ntp_adjtime(&tx);
#else /* !QHAVE_STRUCT_TIMEX_TIME */
	/*
	 * ntp_adjtime() doesn't give us the actual current time, only the
	 * auxiliary time variables.  (D'oh!)  We need a correlated set of
	 * variables, so this is a problem.  We take the auxiliary
	 * variables once, then proceed to get the time, and then get the
	 * auxiliary variables again.  We work with the worst values from
	 * the two sets of auxiliary variables.
	 *
	 * This can theoretically produce wrong results if the clock
	 * state is adjusted (by ntpd) between our syscalls.  For example,
	 * if we read a small tx.offset, then ntpd adjusts the clock by
	 * initiating a larger offset and resets maxerror to be small,
	 * then we read the time with a small maxerror, then the offset
	 * ticks down, then we read the reduced tx.offset.  In that case
	 * we'd never see a tx.offset value as large as that which truly
	 * applies to the time value that we read.  The potential error
	 * in this sort of case is quite small, fortunately.
	 *
	 * We also need a consistent state of the STA_NANO flag, which is
	 * only available from ntp_adjtime().  If it changes between the
	 * two calls then we try again.  If it gets changed twice then we
	 * could get a time value that is inconsistent with the flag state
	 * that we consistently see.  There is no way to prevent this
	 * happening.  Fortunately, it's even less likely than the
	 * failure mode described in the previous paragraph.
	 *
	 * In case it's not clear from the above: memo to OS implementors:
	 * please include the current time in struct timex, so that the
	 * entire clock state can be acquired atomically and thus
	 * coherently.
	 */
	do {
		Zero(&tx, 1, struct timex);
		Zero(&txx, 1, struct timex);
		if(ntp_adjtime(&tx) == -1)
			return 0;
		state = ntp_gettime(&ntv);
		if(ntp_adjtime(&txx) == -1)
			return 0;
	} while((tx.status & STA_NANO) != (txx.status & STA_NANO));
	if(txx.offset > tx.offset)
		tx.offset = txx.offset;
	if(txx.tolerance > tx.tolerance)
		tx.tolerance = txx.tolerance;
#endif /* !QHAVE_STRUCT_TIMEX_TIME */
	if(state == -1 || ntv.time.tv_sec < 0 ||
			(leap_state == TIME_ERROR && demanding_accuracy))
		return 0;
	EXTEND(SP, 5);
	dayno = UNIX_EPOCH_DAYNO + ntv.time.tv_sec / 86400;
	secs = ntv.time.tv_sec % 86400;
	switch(leap_state) {
		case TIME_OK: case TIME_WAIT: {
			/* no extra leap second processing required */
		} break;
		case TIME_DEL: {
			if(secs == 86399) {
				/*
				 * we're apparently in the second being
				 * deleted, and so must delete it ourselves
				 */
				dayno++;
				secs = 0;
			}
		} break;
		case TIME_INS: {
			if(secs == 0) {
				/*
				 * the kernel was supposed to have inserted
				 * a second, but it hasn't got round to it,
				 * so we must do it ourselves
				 */
				dayno--;
				secs = 86400;
			}
		} break;
		case TIME_OOP: {
			if(secs == 86399) {
				/* we're in the leap second */
				secs++;
			} else {
				/*
				 * leap second has actually finished, time
				 * decodes correctly
				 */
			}
		} break;
	}
	PUSHs(sv_2mortal(newSViv(dayno)));
	PUSHs(sv_2mortal(newSViv(secs)));
	PUSHs(sv_2mortal(newSViv((tx.status & STA_NANO) ?
					ntv.time.NTV_SUBSEC :
					ntv.time.NTV_SUBSEC * 1000)));
	if(leap_state != TIME_ERROR) {
		long maxerr = ntv.maxerror + (tx.tolerance >> SHIFT_USEC) + 1;
		long offset = tx.offset < 0 ? -tx.offset : tx.offset;
		long err_s, err_ns;
		err_s = maxerr / 1000000;
		maxerr -= err_s * 1000000;
		if(tx.status & STA_NANO) {
			long offset_s = offset / 1000000000;
			offset -= offset_s * 1000000000;
			err_s += offset_s;
			err_ns = offset + maxerr*1000;
		} else {
			long offset_s = offset / 1000000;
			offset -= offset_s * 1000000;
			err_s += offset_s;
			err_ns = (offset + maxerr) * 1000;
		}
		if(err_ns >= 1000000000) {
			err_s++;
			err_ns -= 1000000000;
		}
		PUSHs(sv_2mortal(newSViv(err_s)));
		PUSHs(sv_2mortal(newSViv(err_ns)));
	} else {
		PUSHs(&PL_sv_undef);
		PUSHs(&PL_sv_undef);
	}
	PUTBACK;
	return 1;
}

#else /* !QHAVE_NTP_ADJTIME */
# define try_ntpadjtime(DA) ((DA), 0)
#endif /* !QHAVE_NTP_ADJTIME */

#ifdef QHAVE_GETSYSTEMTIMEASFILETIME
/*
 * ** use of GetSystemTimeAsFileTime() **
 *
 * This is a Win32 native function.  There is no leap second
 * handling or error bound.  The function returns the number
 * of non-leap seconds since 1601-01-01T00Z, as a 64-bit
 * integer (in two 32-bit halves) in units of 10^-7 s.
 */

# include <windows.h>

# define WINDOWS_EPOCH_MJD (-94187)
# define WINDOWS_EPOCH_DAYNO (WINDOWS_EPOCH_MJD - TAI_EPOCH_MJD)

# if !(defined(HAS_QUAD) && defined(UINT64_C))
static U16 div_u64_u16(U32 *hi_p, U32 *lo_p, U16 d)
{
	U32 hq = *hi_p / d;
	U32 hr = *hi_p % d;
	U32 mid = (hr << 16) | (*lo_p >> 16);
	U32 mq = mid / d;
	U32 mr = mid % d;
	U32 low = (mr << 16) | (*lo_p & 0xffff);
	U32 lq = low / d;
	U32 lr = low % d;
	*lo_p = lq | (mq << 16);
	*hi_p = hq;
	return lr;
}
# endif /* !(HAS_QUAD && UINT64_C) */

static int try_getsystemtimeasfiletime(void)
{
	dSP;
	FILETIME fts;
# if defined(HAS_QUAD) && defined(UINT64_C)
	U64 ftv;
# else /* !(HAS_QUAD && UINT64_C) */
	U32 ft_hi, ft_lo;
	U16 clunks, msec, dasec;
# endif /* !(HAS_QUAD && UINT64_C) */
	fts.dwHighDateTime = 0xffffffff;
	GetSystemTimeAsFileTime(&fts);
	if(fts.dwHighDateTime & 0x80000000)
		/* this appears to be the only way to indicate error */
		return 0;
# if defined(HAS_QUAD) && defined(UINT64_C)
	ftv = (((U64)fts.dwHighDateTime) << 32) | ((U64)fts.dwLowDateTime);
	if(ftv < -WINDOWS_EPOCH_DAYNO * UINT64_C(864000000000))
		return 0;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(
		WINDOWS_EPOCH_DAYNO + ftv / UINT64_C(864000000000))));
	ftv %= UINT64_C(864000000000);
	PUSHs(sv_2mortal(newSViv(ftv / UINT64_C(10000000))));
	PUSHs(sv_2mortal(newSViv(((U32)(ftv % UINT64_C(10000000))) * 100)));
# else /* !(HAS_QUAD && UINT64_C) */
	ft_hi = fts.dwHighDateTime;
	ft_lo = fts.dwLowDateTime;
	clunks = div_u64_u16(&ft_hi, &ft_lo, 10000);
	msec = div_u64_u16(&ft_hi, &ft_lo, 10000);
	dasec = div_u64_u16(&ft_hi, &ft_lo, 8640);
	if(ft_lo < -WINDOWS_EPOCH_DAYNO)
		return 0;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(WINDOWS_EPOCH_DAYNO + ft_lo)));
	PUSHs(sv_2mortal(newSViv(((U32)dasec) * 10 + ((U32)msec)/1000)));
	PUSHs(sv_2mortal(newSViv(
		(((U32)msec)%1000) * 1000000 + ((U32)clunks) * 100)));
# endif /* !(HAS_QUAD && UINT64_C) */
	PUTBACK;
	return 1;
}

#else /* !QHAVE_GETSYSTEMTIMEASFILETIME */
# define try_getsystemtimeasfiletime() (0)
#endif /* !QHAVE_GETSYSTEMTIMEASFILETIME */

#ifdef QHAVE_GETTIMEOFDAY
/*
 * ** use of gettimeofday() **
 *
 * There is no leap second handling or error bound here.
 */

# include <sys/time.h>

static int try_gettimeofday(void)
{
	dSP;
	struct timeval tv;
	if(-1 == gettimeofday(&tv, NULL) || tv.tv_sec < 0)
		return 0;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(UNIX_EPOCH_DAYNO + tv.tv_sec / 86400)));
	PUSHs(sv_2mortal(newSViv(tv.tv_sec % 86400)));
	PUSHs(sv_2mortal(newSViv(tv.tv_usec * 1000)));
	PUTBACK;
	return 1;
}

#else /* !QHAVE_GETTIMEOFDAY */
# define try_gettimeofday() (0)
#endif /* !QHAVE_GETTIMEOFDAY */

/*
 * ** use of Time::Unix::time() **
 *
 * This only gives a resolution of 1 s, and no leap second handling
 * or error bound, but ought to be possible everywhere.  Raw time()
 * doesn't have a consistent epoch across OSes, so we use the
 * Time::Unix wrapper which exists to resolve this.
 */

int try_timeunixtime(void)
{
	dSP;
	int state;
	SV *sv;
	long secs;
	PUSHMARK(SP);
	PUTBACK;
	state = call_pv("Time::Unix::time", G_SCALAR|G_NOARGS);
	SPAGAIN;
	PUTBACK;
	if(state != 1)
		return 0;
	sv = POPs;
	if(!SvIOK(sv))
		return 0;
	secs = SvIVX(sv);
	if(secs < 0)
		return 0;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(UNIX_EPOCH_DAYNO + secs / 86400)));
	PUSHs(sv_2mortal(newSViv(secs % 86400)));
	PUSHs(sv_2mortal(newSViv(500000000)));
	PUTBACK;
	return 1;
}

MODULE = Time::UTC::Now PACKAGE = Time::UTC::Now

void
_now_utc_internal(bool demanding_accuracy)
PROTOTYPE: $
PPCODE:
	PUTBACK;
	if(try_ntpadjtime(demanding_accuracy))
		goto done;
	if(demanding_accuracy)
		croak("can't find time accurately");
	if(try_getsystemtimeasfiletime())
		goto done;
	if(try_gettimeofday())
		goto done;
	if(try_timeunixtime())
		goto done;
	croak("can't find a believable time anywhere");
	done: SPAGAIN;
