=head1 NAME

Time::UTC::Now - determine current time in UTC correctly

=head1 SYNOPSIS

	use Time::UTC::Now qw(now_utc_rat now_utc_sna now_utc_flt);

	($day, $secs, $bound) = now_utc_rat;
	($day, $secs, $bound) = now_utc_rat(1);
	($day, $secs, $bound) = now_utc_sna;
	($day, $secs, $bound) = now_utc_sna(1);
	($day, $secs, $bound) = now_utc_flt;
	($day, $secs, $bound) = now_utc_flt(1);

	use Time::UTC::Now qw(utc_day_to_cjdn);

	$cjdn = utc_day_to_cjdn($day);

=head1 DESCRIPTION

This module is one answer to the question "what time is it?".
It determines the current time on the UTC scale, handling leap seconds
correctly, and puts a bound on how inaccurate it could be.  It is the
rigorously correct approach to determining civil time.  It is designed to
interoperate with L<Time::UTC>, which knows all about the UTC time scale.

UTC (Coordinated Universal Time) is a time scale derived from
International Atomic Time (TAI).  UTC divides time up into days, and
each day into seconds.  The seconds are atomically-realised SI seconds,
of uniform length.  Most UTC days are exactly 86400 seconds long,
but occasionally there is a day of length 86401 s or (theoretically)
86399 s.  These leap seconds are used to keep the UTC day approximately
synchronised with the non-uniform rotation of the Earth.  (Prior to 1972
a different mechanism was used for UTC, but that's not an issue here.)

Because UTC days have differing lengths, instants on the UTC scale
are identified here by the combination of a day number and a number
of seconds since midnight within the day.  In this module the day
number is the integral number of days since 1958-01-01, which is the
epoch of the TAI scale which underlies UTC.  This is the convention
used by the C<Time::UTC> module.  That module has some functions to
format these numbers for display.  For a more general solution, use the
C<utc_day_to_cjdn> function to translate to a standard Chronological
Julian Day Number, which can be used as input to a calendar module.

=cut

package Time::UTC::Now;

use warnings;
use strict;

use Data::Float 0.000 qw(significand_step mult_pow2);
use Module::Runtime 0.001 qw(use_module);
use Time::Unix 1.02 ();
use XSLoader;

our $VERSION = "0.004";

use base qw(Exporter);
our @EXPORT_OK = qw(now_utc_rat now_utc_sna now_utc_flt utc_day_to_cjdn);

XSLoader::load("Time::UTC::Now", $VERSION);

=head1 FUNCTIONS

=over

=item now_utc_rat[(DEMAND_ACCURACY)]

Returns a list of three values.  The first two values identify a current
UTC instant, in the form of a day number (number of days since the TAI
epoch) and a number of seconds since midnight within the day.  The third
value is an inaccuracy bound, as a number of seconds, or C<undef> if no
accurate answer could be determined.

If an inaccuracy bound is returned then this function is claiming to have
answered correctly, to within the specified margin.  That is, some instant
during the execution of C<now_utc_rat> is within the specified margin of
the instant identified.  (This semantic differs from older current-time
interfaces that are content to return an instant that has already passed.)

The inaccuracy bound is measured in UTC seconds; that is, in SI seconds
on the Terran geoid as realised by atomic clocks.  This differs from SI
seconds at the computer's location, but the difference is only apparent
if the computer hardware is significantly time dilated with respect to
the geoid.

If C<undef> is returned instead of an inaccuracy bound then this function
could not find a trustable answer.  Either the clock available was
not properly synchronised or its accuracy could not be established.
Whatever time could be found is returned, but this function makes
no claim that it is accurate.  It should be treated with suspicion.
In practice, clocks of this nature are especially likely to misbehave
around leap seconds.

The function C<die>s if it could not find a plausible time at all.
If DEMAND_ACCURACY is supplied and true then it will also die if it
could not find an accurate answer, instead of returning with C<undef>
for the inaccuracy bound.

All three return values are in the form of C<Math::BigRat> objects.
This retains full resolution, is future-proof, and is easy to manipulate,
but beware that C<Math::BigRat> is currently rather slow.  If performance
is a problem then consider using one of the functions below that return
the results in other formats.

=cut

my $loaded_bigrat;

sub now_utc_rat(;$) {
	use integer;
	my($dayno, $secs, $nsecs, $ubound) = _now_utc_internal($_[0]);
	unless($loaded_bigrat) {
		use_module("Math::BigRat", "0.02");
		$loaded_bigrat = 1;
	}
	return (Math::BigRat->new($dayno),
		Math::BigRat->new(sprintf("%d.%09d", $secs, $nsecs)),
		defined($ubound) ?
			Math::BigRat->new(sprintf("%d.%06d",
						  $ubound / 1000000,
						  $ubound % 1000000)) :
			undef);
}

=item now_utc_sna[(DEMAND_ACCURACY)]

This performs exactly the same operation as C<now_utc_rat>, but returns
the results in a different form.  The day number is returned as a
Perl integer.  The time since midnight and the inaccuracy bound (if
present) are each returned in the form of a three-element array, giving
a high-resolution fixed-point number of seconds.  The first element is
the integral number of whole seconds, the second is an integral number
of nanoseconds in the range [0, 1000000000), and the third is an integral
number of attoseconds in the same range.

This form of return value is fairly efficient.  It is convenient for
decimal output, but awkward to do arithmetic with.  Its resolution is
adequate for the foreseeable future, but could in principle be obsoleted
some day.

It is presumed that native integer formats will grow fast enough to always
represent the day number fully; if not, 31 bits will overflow late in
the sixth megayear of the Common Era.  (Average day length by then is
projected to be around 86520 s, posing more serious problems for UTC.)

The inaccuracy bound describes the actual time represented in the
return values, not an internal value that was rounded to generate the
return values.

=cut

sub now_utc_sna(;$) {
	use integer;
	my($dayno, $secs, $nsecs, $ubound) = _now_utc_internal($_[0]);
	return ($dayno, [$secs, $nsecs, 0],
		defined($ubound) ?
			[ $ubound / 1000000,
			  ($ubound % 1000000) * 1000,
			  0 ] :
			undef);
}

=item now_utc_flt[(DEMAND_ACCURACY)]

This performs exactly the same operation as C<now_utc_rat>, but returns
all the results as Perl numbers (the day number as an integer, with the
same caveat as for C<now_utc_sna>).  This form of return value is very
efficient and easy to manipulate.  However, its resolution is limited,
rendering it obsolete in the near future unless floating point number
formats get bigger.

The inaccuracy bound describes the actual time represented in the
return values, not an internal value that was rounded to generate the
return values.

=cut

# The floating-point seconds value is inaccurate due to rounding for
# binary representation.  (With the resolution currently possible (1 us),
# the conversion to IEEE 754 double doesn't actually lose information,
# but the value still isn't converted exactly.)  Not trusting rounding
# to be correct, allow for 1 ulp of additional error, for values on the
# order of 86400 (exponent +16).  This is added onto the uncertainty.
#
# Also add 1 ulp at 3600 (exponent +11) to cover rounding in conversion
# of the uncertainty value itself.

use constant ADDITIONAL_UNCERTAINTY =>
		 mult_pow2(significand_step, +16) +
		 mult_pow2(significand_step, +11);

sub now_utc_flt(;$) {
	my($dayno, $secs, $nsecs, $ubound) = _now_utc_internal($_[0]);
	return ($dayno,
		$secs + $nsecs/1000000000.0,
		defined($ubound) ? $ubound/1000000.0 + ADDITIONAL_UNCERTAINTY :
			undef);
}

=item utc_day_to_cjdn(DAY)

This function takes a number of days since the TAI epoch and returns
the corresponding Chronological Julian Day Number (a number of days
since -4713-11-24).  CJDN is a standard day numbering that is useful as
an interchange format between implementations of different calendars.
There is no bound on the permissible day numbers.

=cut

use constant _TAI_EPOCH_CJDN => 2436205;

sub utc_day_to_cjdn($) {
	my($day) = @_;
	return _TAI_EPOCH_CJDN + $day;
}

=back

=head1 TECHNIQUES

There are several interfaces available to determine the time on a
computer, and most of them suck.  This module will attempt to use the
best interface available when it runs.  It knows about the following:

=over

=item ntp_adjtime()

Designed for precision timekeeping, this interface gives some leap
second indications and an inaccuracy bound on the time it returns.
Both are faulty in their raw form, but they are corrected by this module.
(Those interested in the gory details are invited to read the source.)
Resolution 1 us.

=item gettimeofday()

Misbehaves around leap seconds, and does not give an inaccuracy bound.
Resolution 1 us.

=item Time::Unix::time()

Misbehaves around leap seconds, and does not give an inaccuracy bound.
Resolution 1 s.  The C<Time::Unix> module corrects for the varying epochs
of C<time()> across OSes; native C<time()> is not a suitable fallback.

=back

The author would welcome patches to this module to make use of
high-precision interfaces, along the lines of C<ntp_adjtime()>, on
non-Unix operating systems.

=head1 SEE ALSO

L<Time::TAI::Now>,
L<Time::UTC>

=head1 AUTHOR

Andrew Main (Zefram) <zefram@fysh.org>

=head1 COPYRIGHT

Copyright (C) 2006 Andrew Main (Zefram) <zefram@fysh.org>

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
