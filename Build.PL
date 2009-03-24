use warnings;
use strict;

use Module::Build;

Module::Build->subclass(code => q{
	unless(__PACKAGE__->can("cbuilder")) {
		*cbuilder = sub { $_[0]->_cbuilder or die "no C support" };
	}
	sub compile_c {
		use Data::Dumper qw(Dumper);
		use IO::File;
		my($self, $file, %args) = @_;
		unless($args{no_feature_defs}) {
			my $feat_file = $self->localize_file_path(
					"lib/Time/UTC/features");
			my $probe_file = $self->localize_file_path(
					"lib/Time/UTC/features.probe");
			unless($self->up_to_date($probe_file, $feat_file)) {
				my $probe = do($probe_file) or
					die $@ || "can't read $probe_file: $!";
				my $feat_defs = $probe->($self);
				$self->add_to_cleanup($feat_file);
				my $feat_fh = IO::File->new($feat_file, "w")
					or die "can't write $feat_file: $!";
				local $Data::Dumper::Terse = 1;
				$feat_fh->printflush(Dumper($feat_defs))
					or die "can't write $feat_file: $!";
			}
			my $feat_defs = do($feat_file) or
				die $@ || "can't read $feat_file: $!";
			$args{defines} =
				{ %{$args{defines} || {}}, %$feat_defs };
			$obj_file = $self->cbuilder->object_file($file);
			unless($self->up_to_date($feat_file, $obj_file)) {
				unlink $obj_file;
			}
		}
		return $self->SUPER::compile_c($file, %args);
	}
})->new(
	module_name => "Time::UTC::Now",
	license => "perl",
	build_requires => {
		"Data::Dumper" => 0,
		"ExtUtils::CBuilder" => "0.15",
		"IO::File" => 0,
		"Module::Build" => 0,
		"Test::More" => 0,
		"perl" => "5.006",
		"strict" => 0,
		"warnings" => 0,
	},
	requires => {
		"Data::Float" => "0.008",
		"Exporter" => 0,
		"Math::BigRat" => "0.02",
		"Module::Runtime" => "0.005",
		"Time::Unix" => "1.02",
		"XSLoader" => 0,
		"constant" => 0,
		"integer" => 0,
		"parent" => 0,
		"perl" => "5.006",
		"strict" => 0,
		"warnings" => 0,
	},
	dynamic_config => 1,
	meta_add => { distribution_type => "module" },
	create_makefile_pl => "passthrough",
	sign => 1,
)->create_build_script;

exit 0;
