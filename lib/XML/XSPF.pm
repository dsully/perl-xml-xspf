package XML::XSPF;

# $Id$

use strict;
use base qw(XML::XSPF::Base);

use Carp;
use Date::Parse;
use HTML::Entities;
use POSIX qw(strftime);
use XML::Parser;
use XML::Writer;

use XML::XSPF::Track;

our $VERSION  = '0.6';

our %defaults = (
	'version' => 1,
	'xmlns'   => 'http://xspf.org/ns/0/',
	'title'   => 'gone with the schwinn',
	'creator' => 'kermit the frog',
);

my @singleValueElements = qw(
	annotation album creator date duration identifier 
	image info license location title trackNum
);

my %uriElements = (

	'playlist' => {
		'identifier' => 1,
		'image'      => 1,
		'info'       => 1,
		'license'    => 1,
		'link'       => 1,
		'location'   => 1,
		'meta'       => 1,
	},

	'track' => {
		'identifier' => 1,
		'image'      => 1,
		'info'       => 1,
		'link'       => 1,
		'location'   => 1,
		'meta'       => 1,
	}
);

{
	my $class = __PACKAGE__;

	# Public Methods
	$class->mk_accessors(qw(
		version charset xmlns title creator annotation location identifier
		info image date license attributions links metas extensions trackList
	));
}

sub parse {
	my ($class, $handle) = @_;

	my $parser = XML::Parser->new(
		'ErrorContext'     => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand'         => 1,
		'NoLWP'            => 1,
		'Handlers'         => {
			'Start' => \&handleStartElement,
			'Char'  => \&handleCharElement,
			'End'   => \&handleEndElement,
		},
	);

	# Stuff instance data needed for parsing the XSPF playlist into the parser object.
	# There's no better way to do this and not have global variables, as
	# Perl5 doesn't have a real 'self' or 'this' object.
	my $self = $class->new;

	$parser->{'_xspf'} = {
		'path'   => undef,
		'self'   => $self,
		'states' => [],
		'track'  => undef,
		'tracks' => [],
	};

	# Handle scalars, scalar refs, filehandles, IO::File, etc.
	if (ref($handle) eq 'SCALAR') {

		eval { $parser->parse($$handle) };

	} elsif (!ref($handle) && -f $handle) {

		eval { $parser->parsefile($handle) };

	} else {

		eval { $parser->parse($handle) };
	}

	if ($@) {
		Carp::confess("Error while parsing playlist: [$@]\n");
		return undef;
	}

	# Playlists MUST have a <trackList> element (even if it's empty version 1)
	if (!$parser->{'_xspf'}->{'trackListCount'}) {

		Carp::confess("Error while parsing playlist - no trackList element!\n");
		return undef;
	}

	$parser = undef;

	return $self;
}

# Create a XSPF document from our in-memory version.
sub toString {
	my $self   = shift;

	my $string = undef;

	my $writer = XML::Writer->new(
		'OUTPUT'      => \$string,
		'DATA_MODE'   => 1,
		'DATA_INDENT' => 4,
	);

	$writer->xmlDecl("UTF-8");

	$writer->startTag('playlist', 'version' => $self->version, 'xmlns' => $self->xmlns);

	for my $element (qw(title creator annotation info location identifier image date license)) {

		if (my $value = $self->$element) {

			$writer->dataElement($element, $value);
		}
	}

	if ($self->attributions) {

		$writer->startTag('attribution');

		for my $attribution ($self->attributions) {

			$writer->dataElement(@{$attribution});
		}

		$writer->endTag('attribution');
	}

	if ($self->trackList) {

		$writer->startTag('trackList');

		for my $track ($self->trackList) {

			$writer->startTag('track');

			for my $element (qw(location identifier)) {

				for my $cdata (@{$track->get("${element}s")}) {

					$writer->dataElement($element, $cdata);
				}
			}

			for my $element (qw(link meta)) {

				for my $cdata (@{$track->get("${element}s")}) {

					$writer->startTag($element, 'rel' => $cdata->[0]);
					$writer->characters($cdata->[1]);
					$writer->endTag($element);
				}
			}

			for my $element (qw(title creator annotation info image album trackNum duration)) {

				if (my $value = $track->$element) {

					$writer->dataElement($element, $value);
				}
			}

			$writer->endTag('track');
		}

		$writer->endTag('trackList');
	}

	$writer->endTag('playlist');
	$writer->end;

	# Don't escape these. XML::Writer provides some basic escaping, but not all.
	$string = encode_entities($string, '^\n\r\t !\#\$%\(-;=?-~<>&"');

	return $string;
}

sub handleStartElement {
	my ($parser, $element, %attributes) = @_;

	# Poor Man's HTML checker - XML::Parser treats elements.
	# So look at the previous element, and if we're a single value
	# element, fail.
	if ($parser->{'_xspf'}->{'path'}) {

		my @parts = split(/\//, $parser->{'_xspf'}->{'path'});
		my $last  = pop @parts;

		if (grep { /^$last$/ } @singleValueElements) {

			Carp::confess("Found HTML markup in <$last>\n");
		}
	}

	my $path = $parser->{'_xspf'}->{'path'} .= "/$element";
	my $self = $parser->{'_xspf'}->{'self'};

	push @{ $parser->{'_xspf'}->{'states'} }, {
		'attributes' => \%attributes,
		'cdata'      => '',
		'path'       => $path,
	};

	# Set some default types once we encounter them.
	if ($path eq '/playlist/attribution') {

		if ($parser->{'_xspf'}->{'attributionCount'}) {

			Carp::confess("Too many attribution elements in playlist!\n");
		}

		$self->set('attributions', []);

		$parser->{'_xspf'}->{'attributionCount'} = 1;
	}

	if ($path eq '/playlist/meta' ||
	    $path eq '/playlist/link') {

		$self->set("${element}s", []);
	}

	if ($path eq '/playlist/trackList') {

		if ($parser->{'_xspf'}->{'trackListCount'}) {

			Carp::confess("Too many trackList elements in playlist!\n");
		}

		$parser->{'_xspf'}->{'trackListCount'} = 1;
	}

	# We got a track entry - create a new object for it
	if ($path eq '/playlist/trackList/track') {

		$parser->{'_xspf'}->{'track'} = XML::XSPF::Track->new;
	}
}

sub handleCharElement {
	my ($parser, $value) = @_;

	# Keep the our little state machine chugging along
	my $state = pop @{ $parser->{'_xspf'}->{'states'} };

	$state->{'cdata'} .= $value;

	push @{ $parser->{'_xspf'}->{'states'} }, $state;
}

sub handleEndElement {
	my ($parser, $element) = @_;

	my $state = pop @{ $parser->{'_xspf'}->{'states'} };
	my $value = $state->{'cdata'};

	my $path  = $parser->{'_xspf'}->{'path'};
	my $self  = $parser->{'_xspf'}->{'self'};

	# These are all single value elements.
	if ($path eq '/playlist/annotation' || 
	    $path eq '/playlist/creator'    || 
	    $path eq '/playlist/date'       || 
	    $path eq '/playlist/identifier' || 
	    $path eq '/playlist/image'      || 
	    $path eq '/playlist/info'       || 
	    $path eq '/playlist/license'    ||
	    $path eq '/playlist/location'   || 
	    $path eq '/playlist/title') {

		# There should only be one value per track according to the spec.
		if ($self->get($element)) {

			Carp::confess("Element: $path has too many values!\n");
		}

		if (_validateLinkElement($path, 'playlist', $element, $value)) {

			$self->$element($value);
		}
	}

	if ($path eq '/playlist/attribution/identifier' ||
	    $path eq '/playlist/attribution/location') {

		if (_validateLinkElement($path, 'playlist', $element, $value)) {

			$self->append('attributions', [ $element, $value ]);
		}
	}

	if ($path eq '/playlist/meta' ||
	    $path eq '/playlist/link') {

		my $rel = $state->{'attributes'}->{'rel'};

		# Check both the value and the rel for validity.
		if (_validateLinkElement($path, 'playlist', $element, $value, $rel)) {

			$self->append("${element}s", [ $rel, $value ]);
		}
	}

	# We've hit the end of a track definition - push it onto the end of the track list.
	if ($path eq '/playlist/trackList/track') {

		push @{ $parser->{'_xspf'}->{'tracks'} }, $parser->{'_xspf'}->{'track'};
	}

	# End of the trackList - set all the tracks we've acquired.
	if ($path eq '/playlist/trackList') {

		$self->trackList($parser->{'_xspf'}->{'tracks'});
	}

	# These can all have multiple values, but we render only one of them
	# per the spec. Should we only store one?
	if ($path eq '/playlist/trackList/track/location' ||
	    $path eq '/playlist/trackList/track/identifier') {

		if (_validateLinkElement($path, 'track', $element, $value)) {

			$parser->{'_xspf'}->{'track'}->append("${element}s", $value);
		}
	}

	if ($path eq '/playlist/trackList/track/meta' ||
	    $path eq '/playlist/trackList/track/link') {

		my $rel = $state->{'attributes'}->{'rel'};

		# Check both the value and the rel for validity.
		if (_validateLinkElement($path, 'track', $element, $value, $rel)) {

			$parser->{'_xspf'}->{'track'}->append("${element}s", [ $rel, $value ]);
		}
	}

	# Single element track values.
	if ($path eq '/playlist/trackList/track/album' || 
	    $path eq '/playlist/trackList/track/annotation' || 
	    $path eq '/playlist/trackList/track/creator' || 
	    $path eq '/playlist/trackList/track/duration' || 
	    $path eq '/playlist/trackList/track/image' || 
	    $path eq '/playlist/trackList/track/info' || 
	    $path eq '/playlist/trackList/track/title' || 
	    $path eq '/playlist/trackList/track/trackNum') {

		# There should only be one value per track according to the spec.
		if ($parser->{'_xspf'}->{'track'}->get($element)) {

			Carp::confess("Element: $element has too many values!\n");
		}

		# Check for invalid URIs
		if (_validateLinkElement($path, 'track', $element, $value)) {

			$parser->{'_xspf'}->{'track'}->$element($value);
		}
	}

	if ($path eq '/playlist') {

		for my $attr (qw(version xmlns)) {

			if (defined $state->{'attributes'}->{$attr}) {

				$self->$attr($state->{'attributes'}->{$attr});

			} else {

				Carp::confess("Didn't find $attr in the <playlist> element!\n");
			}
		}
	}

	my @parts = split(/\//, $path);
	pop @parts;
	$parser->{'_xspf'}->{'path'} = join('/', @parts);
}

sub version {
	my $self = shift;

	if (defined $_[0] && $_[0] !~ /^[01]$/) {

		Carp::confess("XSPF Version is not 0 or 1!\n");
	}

	return $self->_getSetWithDefaults('version', \%defaults, @_);
}

sub xmlns {
	my $self = shift;

	if (defined $_[0] && $_[0] ne 'http://xspf.org/ns/0/') {

		Carp::confess("xmlns MUST be http://xspf.org/ns/0/\n");
	}

	return $self->_getSetWithDefaults('xmlns', \%defaults, @_);
}

sub title {
	shift->_getSetWithDefaults('title', \%defaults, @_);
}

sub creator {
	shift->_getSetWithDefaults('creator', \%defaults, @_);
}

# Store the incoming time - either ISO 8601 or xsd:dateTime, and format it on
# the way out as xsd:dateTime for version 1.
sub date {
	my $self = shift;

	if (@_) {

		my $date = str2time($_[0]);

		if ($date && $date =~ /^\d+$/) {

			$self->set('date', $date);

		} else {

			Carp::confess("Invalid date: [$_[0]]\n");
		}

	} else {

		# Check the version to determine the date format.
		# If the date isn't set - use the current date
		my $date = $self->get('date') || time;

		if ($self->version == 0) {

			return strftime('%Y-%m-%d', localtime($date));

		} elsif ($self->version == 1) {

			my $xsd  = strftime('%Y-%m-%dT%H:%M:%S', localtime($date));
			my $tz   = strftime('%z', localtime($date));
			   $tz   =~ s/^([+-]\d{2})/$1:/;

			return $xsd . $tz;

		} else {

			Carp::confess("Couldn't figure out date format from version: [%d]\n", $self->version);
		}
	}
}

sub trackList {
	shift->_asArray('trackList', @_);
}

sub metas {
	shift->_asArray('metas', @_);
}

sub links {
	shift->_asArray('links', @_);
}

sub attributions {
	shift->_asArray('attributions', @_);
}

sub _validateLinkElement {
	my ($path, $parent, $element, $value, $rel) = @_;

	if ($uriElements{$parent}->{$element}) {

		if (!_isValidURI($value)) {
			Carp::confess("Element: $path ($value) is not a valid URI!\n");
		}

		if ($rel && !_isValidURI($rel)) {

			Carp::confess("Element: $path rel ($rel) value is not a valid URI!\n");
		}
	}

	return 1;
}

sub _isValidURI {
	my $uri = shift;

	return if $uri =~ /[^a-z0-9\:\/\?\#\[\]\@\!\$\&\'\(\)\*\+\,\;\=\.\-\_\~]/i;
	return 1;
}

1;

__END__

=head1 NAME

XML::XSPF - API for reading & writing XSPF Playlists

=head1 SYNOPSIS

  use strict;
  use XML::XSPF;
  use XML::XSPF::Track;

  my $playlist = XML::XSPF->parse($filenameOrString);

  print "count: " . $playlist->trackList . "\n";

  for my $track ($playlist->trackList) {

    if ($track->title) {
         print $track->title . "\n";
    }

    if ($track->location) {
         print $track->location . "\n";
    }
  }

  my $xspf  = XML::XSPF->new;
  my $track = XML::XSPF::Track->new;

  $track->title('Prime Evil');
  $track->location('http://orb.com/PrimeEvil.mp3');

  $xspf->title('Bicycles & Tricycles');
  $xspf->trackList($track);

  print $xspf->toString;

=head1 DESCRIPTION

This is a parser and generator for the XSPF playlist format.

=head1 METHODS

=over 4

=item * new()

Create a new instance of an XML::XSPF object.

=item * parse( filenameOrString )

Create a XML::XSPF object, parsing the playlist in filenameOrString

=item * toString()

Serialize a XML::XSPF object back to XML

=item * accessors

Call ->title, ->creator, ->trackList, etc to get the values for the corresponding XSPF nodes.

=back

=head1 BUGS

=over 4

=item * Extensions are not handled yet.

=item * Multiple xmlns attributes are not handled properly. 

=item * Only UTF-8 Encoding is handled currently.

=back

=head1 SEE ALSO

=over 4

=item XSPF Version 1 Spec:

  http://www.xspf.org/xspf-v1.html

=item Slim Devices:

  http://www.slimdevices.com/

=back

=head1 AUTHOR

Dan Sully E<lt>dan | at | slimdevices.comE<gt> & Slim Devices, Inc.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2006 Dan Sully & Slim Devices, Inc. All rights reserved. 

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

=cut
