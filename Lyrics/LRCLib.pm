package Plugins::MusicArtistInfo::Lyrics::LRCLib;

use strict;

use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);
use Time::HiRes;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# LRCLib used to hang responses, therefore we used a proxy. But that seems to no longer be needed
use constant BASE_URL => 'https://lrclib.net/api/';
# use constant BASE_URL_PROXIED => 'http://localhost:8787/music/LRCLibProxy/';
use constant BASE_URL_PROXIED => 'https://api.lms-community.org/music/LRCLibProxy/';
use constant GET_URL => 'get?artist_name=%s&track_name=%s&album_name=%s&duration=%s';
use constant SEARCH_URL => 'search?artist_name=%s&track_name=%s&album_name=%s';

# if we have different durations in a search result, accept a maximum difference of X seconds
use constant MAX_DURATION_DIFF => 5;
use constant MAX_LAG_BEFORE_PROXYING => 5;
use constant PROXYING_PERIOD => 60 * 60;    # reset proxying after an hour, to see whether the situation has improved

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $useLRCProxy = 0;

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

	return $cb->() unless $args->{artist} && $args->{title} && $args->{album} && $args->{duration};

	_call(
		sprintf(GET_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title}), uri_escape_utf8($args->{album} || '.'), $args->{duration} || 1),
		sub {
			my $result = shift;

			if ($result && ref $result && ($result->{plainLyrics} || $result->{syncedLyrics})) {
				return $cb->({
					song => $args->{title},
					artist => $args->{artist},
					lyrics => $result->{syncedLyrics} || $result->{plainLyrics},
				});
			}

			$cb->();
		}
	);

	return;
}


sub searchLyrics {
	my ( $class, $args, $cb ) = @_;

	return $cb->() unless $args->{artist} && $args->{title};

	_call(
		sprintf(SEARCH_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title}), uri_escape_utf8($args->{album})),
		sub {
			my $result = shift;

			if ($result && ref $result && ref $result eq 'ARRAY' && scalar @$result) {
				my $artist = lc($args->{artist});
				my $track  = lc($args->{title});
				my $duration = $args->{duration};

				$result = [ grep {
					$_ && ref $_ && ($_->{plainLyrics} || $_->{syncedLyrics})
				} @$result ];

				my $useSynced;

				if ($duration) {
					# if we have a duration, sort candidates by closest duration
					$result = [ sort {
						abs($a->{duration} - $args->{duration}) <=> abs($b->{duration} - $args->{duration})
					} @$result ];
				}
				else {
					# without a duration given, only use synced lyrics if all candidates have similar durations
					my ($min, $max);
					foreach (@$result) {
						$min ||= $_->{duration};
						$max ||= $_->{duration};
						$min = min($min, $_->{duration});
						$max = max($max, $_->{duration});
					}
					$useSynced = (($max - $min) <= MAX_DURATION_DIFF);
				}

				my ($lyrics) = grep {
					lc($_->{artistName}) eq $artist && lc($_->{trackName}) eq $track;
				} @$result;

				if (!$lyrics) {
					($lyrics) = grep {
						$_->{artist} =~ /\Q$artist\E/i && $_->{trackName} =~ /\Q$track\E/i;
					} @$result;
				}

				if ($duration && $lyrics) {
					$useSynced = abs($lyrics->{duration} - $duration) <= MAX_DURATION_DIFF;
				}

				return $cb->({
					song => $lyrics->{title},
					artist => $lyrics->{artist},
					lyrics => ($useSynced && $lyrics->{syncedLyrics}) || $lyrics->{plainLyrics},
				}) if $lyrics;
			}

			$cb->();
		}
	);

	return;
}

sub _call {
	my ($url, $cb) = @_;

	my $startTime = Time::HiRes::time();

	__call(
		$url,
		sub {
			my ($result) = @_;

			if (!_useLRCProxy() && Time::HiRes::time() - $startTime > MAX_LAG_BEFORE_PROXYING) {
				main::INFOLOG && $log->is_info && $log->info("LRCLib is taking a long time to respond - enabling proxying");
				$useLRCProxy = 1;

				# but don't proxy forever...
				Slim::Utils::Timers::killTimers(__PACKAGE__, \&_resetProxying);
				Slim::Utils::Timers::setTimer(__PACKAGE__, time() + PROXYING_PERIOD, \&_resetProxying);
			}

			$cb->($result);
		},{
			timeout => 5,
			cache => 1,
			expires => 86400,
			ignoreError => [404]
		}
	);
}

sub __call {
	my $url = shift;

	if (_useLRCProxy()) {
		require Plugins::MusicArtistInfo::API;
		Plugins::MusicArtistInfo::API::_call(BASE_URL_PROXIED . $url, @_);
	}
	else {
		Plugins::MusicArtistInfo::Common->call(BASE_URL . $url, @_);
	}
}

sub _resetProxying {
	$useLRCProxy = 0;
	main::INFOLOG && $log->is_info && $log->info("LRCLib proxying disabled again");
}

sub _useLRCProxy {
	return $useLRCProxy || $prefs->get('forceLRCProxy');
}

1;