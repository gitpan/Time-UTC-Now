#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#ifdef QUSE_NTP_ADJTIME
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
#endif /* QUSE_NTP_ADJTIME */

#ifdef QUSE_GETTIMEOFDAY
# include <sys/time.h>
#endif /* QUSE_GETTIMEOFDAY */

#define TAI_EPOCH_MJD 36204
#define UNIX_EPOCH_MJD 40587
#define UNIX_EPOCH_DAYNO (UNIX_EPOCH_MJD - TAI_EPOCH_MJD)

MODULE = Time::UTC::Now PACKAGE = Time::UTC::Now

void
_now_utc_internal(SV *sv_demanding_accuracy)
PROTOTYPE: $
INIT:
	int demanding_accuracy;
	int state;
	long secs;
	SV *sv;
#ifdef QUSE_NTP_ADJTIME
	struct timex tx;
	long dayno;
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
#endif /* QUSE_NTP_ADJTIME */
#ifdef QUSE_GETTIMEOFDAY
	struct timeval tv;
#endif /* QUSE_GETTIMEOFDAY */
PPCODE:
	demanding_accuracy = SvTRUE(sv_demanding_accuracy);
#ifdef QUSE_NTP_ADJTIME
	/*
	 * ** trying ntp_adjtime() **
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
			goto no_ntp_adjtime;
		state = ntp_gettime(&ntv);
		if(ntp_adjtime(&txx) == -1)
			goto no_ntp_adjtime;
	} while((tx.status & STA_NANO) != (txx.status & STA_NANO));
	if(txx.offset > tx.offset)
		tx.offset = txx.offset;
	if(txx.tolerance > tx.tolerance)
		tx.tolerance = txx.tolerance;
#endif /* !QHAVE_STRUCT_TIMEX_TIME */
	if(state == -1 || ntv.time.tv_sec < 0 ||
			(leap_state == TIME_ERROR && demanding_accuracy))
		goto no_ntp_adjtime;
	EXTEND(SP, 4);
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
		long offset = tx.offset < 0 ? -tx.offset : tx.offset;
		if(tx.status & STA_NANO) offset = (offset / 1000) + 1;
		PUSHs(sv_2mortal(newSViv(
			ntv.maxerror +
			(tx.tolerance >> SHIFT_USEC) +
			offset + 1)));
	} else {
		PUSHs(&PL_sv_undef);
	}
	goto done;
	no_ntp_adjtime: ;
#endif /* QUSE_NTP_ADJTIME */
	if(demanding_accuracy)
		croak("can't find time accurately");
#ifdef QUSE_GETTIMEOFDAY
	/*
	 * ** trying gettimeofday() **
	 *
	 * There is no leap second handling or error bound here.
	 */
	if(-1 == gettimeofday(&tv, NULL) || tv.tv_sec < 0)
		goto no_gettimeofday;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(
		UNIX_EPOCH_DAYNO + tv.tv_sec / 86400)));
	PUSHs(sv_2mortal(newSViv(tv.tv_sec % 86400)));
	PUSHs(sv_2mortal(newSViv(tv.tv_usec * 1000)));
	goto done;
	no_gettimeofday: ;
#endif /* QUSE_GETTIMEOFDAY */
	/*
	 * ** trying Time::Unix::time() **
	 *
	 * This only gives a resolution of 1 s, and no leap second handling
	 * or error bound, but ought to be possible everywhere.  Raw time()
	 * doesn't have a consistent epoch across OSes, so we use the
	 * Time::Unix wrapper which exists to resolve this.
	 */
	PUSHMARK(SP);
	PUTBACK;
	state = call_pv("Time::Unix::time", G_SCALAR|G_NOARGS);
	SPAGAIN;
	PUTBACK;
	if(state != 1)
		goto no_unix_time;
	sv = POPs;
	if(!SvIOK(sv))
		goto no_unix_time;
	secs = SvIV(sv);
	if(secs < 0)
		goto no_unix_time;
	EXTEND(SP, 3);
	PUSHs(sv_2mortal(newSViv(UNIX_EPOCH_DAYNO + secs / 86400)));
	PUSHs(sv_2mortal(newSViv(secs % 86400)));
	PUSHs(sv_2mortal(newSViv(500000000)));
	goto done;
	no_unix_time: ;
	/*
	 * ** time not available at all **
	 */
	croak("can't find a believable time anywhere");
	done: ;
