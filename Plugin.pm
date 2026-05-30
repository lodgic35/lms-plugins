package Plugins::StreamWatchdog::Plugin;

# StreamWatchdog - LMS Plugin v1.7
# Monitors players and automatically restarts playback if audio stops
# unexpectedly. Handles both Spotty/Spotify and internet radio streams.
#
# Detection methods:
#   1. Player mode changes to 'stop' unexpectedly
#   2. Player stays in 'play' mode but track time position freezes (hang)
#
# Recovery logic:
#   If internet DOWN  -> wait patiently, resume Spotify when internet returns
#   If internet UP    -> attempt Spotify recovery (token refresh + stop/play)
#                     -> after max retries, switch to fallback radio (from Favourites)

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Control::Request;
use Time::HiRes qw(time);

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.streamwatchdog',
    'defaultLevel' => 'INFO',
    'description'  => 'Stream Watchdog',
});

my $prefs = preferences('plugin.streamwatchdog');

$prefs->init({
    enabled          => 1,
    poll_interval    => 15,
    debounce_delay   => 10,
    max_retries      => 5,
    backoff_seconds  => 30,
    cooldown_minutes => 10,
    freeze_threshold => 30,
    fallback_enabled => 1,
    fallback_url     => '',
    fallback_title   => '',
    ping_host        => '8.8.8.8',
});

my %playerState;

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Plugins::StreamWatchdog::Settings;
    Plugins::StreamWatchdog::Settings->new($class);

    Slim::Control::Request::subscribe(
        \&_onPlayerCommand,
        [['playlist'], ['play', 'pause', 'stop', 'clear', 'index']]
    );

    Slim::Control::Request::subscribe(
        \&_onPowerCommand,
        [['power']]
    );

    _schedulePoll();

    $log->info("Stream Watchdog v1.7 initialised. Poll: "
        . $prefs->get('poll_interval') . "s, Freeze: "
        . $prefs->get('freeze_threshold') . "s, Fallback: "
        . ($prefs->get('fallback_title') || 'not set'));
}

sub _schedulePoll {
    Slim::Utils::Timers::killTimers(undef, \&_pollAllPlayers);
    Slim::Utils::Timers::setTimer(
        undef,
        time() + $prefs->get('poll_interval'),
        \&_pollAllPlayers
    );
}

sub _internetUp {
    my $host   = $prefs->get('ping_host') || '8.8.8.8';
    my $result = system("ping -c 1 -W 3 $host >/dev/null 2>&1");
    return $result == 0 ? 1 : 0;
}

sub _onPlayerCommand {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();
    my $cmd     = $request->getRequest(1) // '';

    if ($cmd eq 'play') {
        $playerState{$id}{userStopped}        = 0;
        $playerState{$id}{retries}            = 0;
        $playerState{$id}{stopTime}           = undef;
        $playerState{$id}{cooldownUntil}      = 0;
        $playerState{$id}{lastPlayTime}       = time();
        $playerState{$id}{hangDetected}       = 0;
        $playerState{$id}{lastTrackTime}      = undef;
        $playerState{$id}{lastTrackTimeSeen}  = time();
        $playerState{$id}{waitingForInternet} = 0;
        $playerState{$id}{usingFallback}      = 0;
        _recordTrackInfo($client);
        $log->debug("[$id] User play - watchdog reset");

    } elsif ($cmd eq 'pause') {
        $playerState{$id}{userStopped}  = 1;
        $playerState{$id}{hangDetected} = 0;
        $log->debug("[$id] User pause - watchdog suppressed");

    } elsif ($cmd eq 'stop' || $cmd eq 'clear') {
        $playerState{$id}{userStopped}        = 1;
        $playerState{$id}{retries}            = 0;
        $playerState{$id}{hangDetected}       = 0;
        $playerState{$id}{waitingForInternet} = 0;
        $playerState{$id}{usingFallback}      = 0;
        $log->debug("[$id] User stop/clear - watchdog suppressed");

    } elsif ($cmd eq 'index') {
        $playerState{$id}{userStopped}       = 0;
        $playerState{$id}{retries}           = 0;
        $playerState{$id}{stopTime}          = undef;
        $playerState{$id}{hangDetected}      = 0;
        $playerState{$id}{lastTrackTime}     = undef;
        $playerState{$id}{lastTrackTimeSeen} = time();
        _recordTrackInfo($client);
        $log->debug("[$id] User skip - watchdog reset");
    }
}

sub _onPowerCommand {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();
    my $power   = $request->getParam('_newvalue') // 1;
    if (!$power) {
        $playerState{$id}{userStopped}        = 1;
        $playerState{$id}{hangDetected}       = 0;
        $playerState{$id}{waitingForInternet} = 0;
        $log->debug("[$id] Power off - watchdog suppressed");
    }
}

sub _recordTrackInfo {
    my $client = shift;
    my $id     = $client->id();
    my $url    = Slim::Player::Playlist::url($client) // '';

    $playerState{$id}{lastURI}           = $url;
    $playerState{$id}{lastPlaylistIndex} = Slim::Player::Source::streamingSongIndex($client) // 0;

    if ($url =~ /^spotty:|spotify:|^https?:\/\/.*spotify/i) {
        $playerState{$id}{sourceType} = 'spotify';
    } elsif ($url =~ /^https?:\/\//i) {
        $playerState{$id}{sourceType} = 'radio';
    } else {
        $playerState{$id}{sourceType} = 'unknown';
    }

    $log->debug("[$id] Recorded: $url (type: $playerState{$id}{sourceType})");
}

sub _pollAllPlayers {
    _schedulePoll();
    return unless $prefs->get('enabled');
    for my $client (Slim::Player::Client::clients()) {
        next unless $client->isPlayer();
        _checkPlayer($client);
    }
}

sub _checkPlayer {
    my $client = shift;
    my $id     = $client->id();

    return unless $client->power();

    my $mode = Slim::Player::Source::playmode($client);

    if ($playerState{$id}{waitingForInternet} && $mode ne 'play') {
        if (_internetUp()) {
            $log->info("[$id] Internet restored - attempting resume");
            $playerState{$id}{waitingForInternet} = 0;
            $playerState{$id}{retries}            = 0;
            $playerState{$id}{stopTime}           = undef;
            $client->execute(['play']);
            return;
        } else {
            $log->debug("[$id] Still waiting for internet...");
            return;
        }
    }

    if ($mode eq 'play') {
        _checkForHang($client);
        return;
    }

    $playerState{$id}{hangDetected}      = 0;
    $playerState{$id}{lastTrackTime}     = undef;
    $playerState{$id}{lastTrackTimeSeen} = undef;

    return if $playerState{$id}{userStopped};
    return unless $playerState{$id}{lastPlayTime};

    my $cooldownUntil = $playerState{$id}{cooldownUntil} // 0;
    if (time() < $cooldownUntil) {
        $log->debug("[$id] In cooldown");
        return;
    }

    unless ($playerState{$id}{stopTime}) {
        $playerState{$id}{stopTime} = time();
        $log->info("[$id] Unexpected stop (mode: $mode) - debouncing");
        return;
    }

    my $stopDuration = time() - $playerState{$id}{stopTime};
    if ($stopDuration < $prefs->get('debounce_delay')) {
        $log->debug("[$id] Debouncing...");
        return;
    }

    _attemptRecovery($client, 'unexpected stop');
}

sub _checkForHang {
    my $client      = shift;
    my $id          = $client->id();
    my $currentTime = $client->controller()->playingSongElapsed() // 0;
    my $lastTime    = $playerState{$id}{lastTrackTime};
    my $lastSeen    = $playerState{$id}{lastTrackTimeSeen} // time();

    if (!defined $lastTime) {
        $playerState{$id}{lastTrackTime}     = $currentTime;
        $playerState{$id}{lastTrackTimeSeen} = time();
        $playerState{$id}{lastPlayTime}      = time();
        _recordTrackInfo($client);
        $log->debug("[$id] Track time init: ${currentTime}s");
        return;
    }

    if ($currentTime != $lastTime) {
        $playerState{$id}{lastTrackTime}      = $currentTime;
        $playerState{$id}{lastTrackTimeSeen}  = time();
        $playerState{$id}{lastPlayTime}       = time();
        $playerState{$id}{hangDetected}       = 0;
        $playerState{$id}{userStopped}        = 0;
        $playerState{$id}{waitingForInternet} = 0;
        _recordTrackInfo($client);
        $log->debug("[$id] Track advancing: ${currentTime}s");
        return;
    }

    my $frozenFor = time() - $lastSeen;
    $log->debug("[$id] Frozen at ${currentTime}s for ${frozenFor}s");

    if ($frozenFor >= $prefs->get('freeze_threshold')) {
        my $cooldownUntil = $playerState{$id}{cooldownUntil} // 0;
        return if time() < $cooldownUntil;
        return if $playerState{$id}{userStopped};

        $log->warn("[$id] HANG DETECTED - frozen at ${currentTime}s for ${frozenFor}s");
        $playerState{$id}{hangDetected}      = 1;
        $playerState{$id}{lastTrackTime}     = undef;
        $playerState{$id}{lastTrackTimeSeen} = undef;
        $playerState{$id}{stopTime}          = time() unless $playerState{$id}{stopTime};

        _attemptRecovery($client, 'hang');
    }
}

sub _attemptRecovery {
    my ($client, $reason) = @_;
    my $id         = $client->id();
    my $retries    = $playerState{$id}{retries} // 0;
    my $maxRetries = $prefs->get('max_retries');
    my $source     = $playerState{$id}{sourceType} // 'unknown';

    my $online = _internetUp();

    if (!$online) {
        $playerState{$id}{waitingForInternet} = 1;
        $log->warn("[$id] Internet is DOWN - waiting for connection (reason: $reason)");
        return;
    }

    $log->info("[$id] Internet is UP - recovering (reason: $reason, source: $source)");

    if ($retries >= $maxRetries) {
        if ($prefs->get('fallback_enabled') && $prefs->get('fallback_url')) {
            _switchToFallback($client);
        } else {
            my $cooldownSecs = $prefs->get('cooldown_minutes') * 60;
            $playerState{$id}{cooldownUntil} = time() + $cooldownSecs;
            $playerState{$id}{retries}       = 0;
            $playerState{$id}{stopTime}      = undef;
            $log->warn("[$id] Max retries reached, no fallback configured - cooling down");
        }
        return;
    }

    my $backoff  = $prefs->get('backoff_seconds') * (1 + $retries * 0.5);
    my $stopTime = $playerState{$id}{stopTime} // time();
    my $elapsed  = time() - $stopTime;

    if ($retries > 0 && $elapsed < $backoff) {
        $log->debug("[$id] Backoff ($elapsed s < $backoff s)");
        return;
    }

    $playerState{$id}{retries}++;
    my $attempt = $playerState{$id}{retries};

    $log->warn("[$id] Recovery attempt $attempt/$maxRetries - reason: $reason, source: $source");

    if ($source eq 'spotify') {
        _recoverSpotify($client);
    } elsif ($source eq 'radio') {
        _recoverRadio($client);
    } else {
        _recoverGeneric($client);
    }
}

sub _switchToFallback {
    my $client = shift;
    my $id     = $client->id();
    my $favid  = $prefs->get('fallback_url');
    my $title  = $prefs->get('fallback_title') || 'Fallback Radio';

    $log->warn("[$id] Switching to fallback radio: $title (id: $favid)");

    $client->execute(['favorites', 'playlist', 'play', 'item_id:' . $favid]);

    $playerState{$id}{usingFallback}      = 1;
    $playerState{$id}{retries}            = 0;
    $playerState{$id}{stopTime}           = undef;
    $playerState{$id}{userStopped}        = 0;
    $playerState{$id}{waitingForInternet} = 0;
    $playerState{$id}{sourceType}         = 'radio';
}

sub _recoverSpotify {
    my $client  = shift;
    my $id      = $client->id();
    my $retries = $playerState{$id}{retries} // 1;

    $log->info("[$id] Spotify recovery: attempt $retries");

    my $playlistSize = Slim::Player::Playlist::count($client) // 0;
    my $currentIndex = Slim::Player::Source::streamingSongIndex($client) // 0;

    if ($retries <= 2) {
        $log->info("[$id] Spotify: token refresh + stop/play cycle");
        eval { $client->execute(['spotty', 'refresh']); };
        if ($@) { $log->warn("[$id] Spotty refresh failed: $@"); }

        Slim::Utils::Timers::setTimer(
            $client,
            time() + 3,
            sub {
                my $c = shift;
                return unless $c;
                my $cid = $c->id();
                $log->info("[$cid] Spotify: issuing stop");
                $c->execute(['stop']);
                Slim::Utils::Timers::setTimer(
                    $c,
                    time() + 2,
                    sub {
                        my $c2 = shift;
                        return unless $c2;
                        my $cid2 = $c2->id();
                        $log->info("[$cid2] Spotify: issuing play after stop");
                        $c2->execute(['play']);
                    }
                );
            }
        );

    } else {
        $log->info("[$id] Spotify: skipping to next track (attempt $retries)");
        if ($playlistSize > 1 && $currentIndex < $playlistSize - 1) {
            $client->execute(['playlist', 'index', '+1']);
            $log->info("[$id] Skipped to track " . ($currentIndex + 2) . " of $playlistSize");
        } else {
            $log->info("[$id] Restarting from track 1");
            $client->execute(['playlist', 'index', '0']);
            Slim::Utils::Timers::setTimer(
                $client, time() + 1,
                sub {
                    my $c = shift;
                    return unless $c;
                    $c->execute(['play']);
                }
            );
        }
    }
}

sub _recoverRadio {
    my $client = shift;
    my $id     = $client->id();
    $log->info("[$id] Radio recovery: issuing play");
    $client->execute(['play']);
}

sub _recoverGeneric {
    my $client = shift;
    my $id     = $client->id();
    $log->info("[$id] Generic recovery: issuing play");
    $client->execute(['play']);
}

sub getFavourites {
    my $favs = [];

    my $request = Slim::Control::Request->new(
        undef,
        ['favorites', 'items', 0, 100]
    );
    $request->execute();

    my $items = $request->getResult('item_loop') || [];
    for my $item (@{$items}) {
        next unless $item->{id};
        next if $item->{hasitems};
        push @{$favs}, {
            id    => $item->{id},
            title => $item->{name} || $item->{id},
        };
    }

    my $count = $request->getResult('count') || 0;
    $log->info("Favourites: found $count items, " . scalar(@{$favs}) . " playable items");

    return $favs;
}

sub getDisplayName { 'PLUGIN_STREAMWATCHDOG' }
sub playerMenu     { undef }

1;
