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

=head1 DESCRIPTION

This module is one answer to the question "what time is it?".
It determines the current time on the UTC scale, handling leap seconds
correctly, and puts a bound on how inaccurate it could be.  It is the
rigorously correct approach to determining civil time.  It is designed to
interoperate with L<Time::UTC>, which knows all about the UTC time scale.

=head1 STRUCTURE OF UTC

UTC is a time scale derived from International Atomic Time (TAI).
UTC divides time up into days, and each day into seconds.  The seconds
are atomically-realised SI seconds, of uniform length.  Most UTC days
are exactly 86400 seconds long, but occasionally there is a day of length
86401 s or (theoretically) 86399 s.  These leap seconds are used to keep
the UTC day approximately synchronised with the non-uniform rotation
of the Earth.  (Prior to 1972 a different mechanism was used for UTC,
but that's not an issue here.)

Because UTC days have differing lengths, instants on the UTC scale are
identified by the combination of a day number and a number of seconds
since midnight within the day.  The day number is the integral number
of days since 1958-01-01, which is the epoch of the TAI scale which
underlies UTC.  This convention is used for interoperability with the
C<Time::UTC> module.  See that module for functions to format these
numbers for display.

=cut

package Time::UTC::Now;

use warnings;
use strict;

use Module::Runtime 0.001 qw(use_module);
use Time::Unix 1.02 ();
use XSLoader;

our $VERSION = "0.000";

use base qw(Exporter);
our @EXPORT_OK = qw(now_utc_rat now_utc_sna now_utc_flt);

XSLoader::load("Time::UTC::Now", $VERSION);

=head1 FUNCTIONS

=over

=item now_utc_rat[(DEMAND_ACCURACY)]

Returns a list of three values.  The first two values identify a current
UTC instant, in the form of a day number and a number of seconds since
midnight within the day.  The third value is an inaccuracy bound, as a
number of seconds, or C<undef> if no accurate answer could be determined.

If an inaccuracy bound is returned then this function is claiming to
have answered correctly, to within the specified margin.  That is, some
instant during the execution of C<now_utc> is within the specified margin
of the instant identified.  (This semantic differs from older current-time
interfaces that are content to return an instant that has already passed.)

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

This performs exactly the same operation as C<now_utc_rat>, but
returns all the results as Perl numbers (the day number as an integer).
This form of return value is very efficient and easy to manipulate.
However, its resolution is limited, rendering it obsolete in the near
future unless floating point number formats get bigger.

=cut

sub now_utc_flt(;$) {
	my($dayno, $secs, $nsecs, $ubound) = _now_utc_internal($_[0]);
	# The floating-point seconds value is inaccurate due to
	# rounding for binary representation.  (With the resolution
	# currently possible (1 us), the conversion doesn't actually
	# lose information, but the value still isn't converted exactly.)
	# Epsilon for values on the order of 86400 in a 52-bit significand
	# is 2^-36, so if rounding is correct then the maximum possible
	# additional error is 2^-37.  I don't trust the rounding to
	# be correct, so declare an additional inaccuracy of 2^-36 s.
	# This analysis assumes that the floating point format is IEEE
	# 754 double or something similar.
	return ($dayno,
		$secs + $nsecs/1000000000.0,
		defined($ubound) ? $ubound/1000000.0 + 1.5e-11 : undef);
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
of C<time()> across OSes.

=back

The author would welcome patches to this module to make use of
high-precision interfaces, along the lines of C<ntp_adjtime()>, on
non-Unix operating systems.

=head1 SEE ALSO

L<Time::UTC>

=head1 AUTHOR

Andrew Main (Zefram) <zefram@fysh.org>

=head1 COPYRIGHT

Copyright (C) 2006 Andrew Main (Zefram) <zefram@fysh.org>

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
