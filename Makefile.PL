use 5.008001;
use ExtUtils::MakeMaker;
use Config;

die "Data::Alias does not support 5.005 threads\n" if $Config{use5005threads};

WriteMakefile(
	NAME		=> 'Data::Alias',
	VERSION_FROM	=> 'lib/Data/Alias.pm',
	ABSTRACT_FROM	=> 'lib/Data/Alias.pm',
	AUTHOR		=> 'Matthijs van Duin <xmath@cpan.org>'
);
