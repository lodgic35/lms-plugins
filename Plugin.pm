package Plugins::StreamWatchdog::Plugin;

# StreamWatchdog - LMS Plugin v2.0
# Monitors players and automatically restarts playback if audio stops
# unexpectedly. Handles both Spotty/Spotify and internet radio streams.
#
# Detection methods:
#   1. Player mode changes to 'stop' unexpectedly
#   2. Track time freeze (player in 'play' but time not advancing)
#   3. Byte stall (no data received and buffer empty)
#
# Recovery logic:
#   Internet DOWN  -> wait patiently, resume when internet returns
#   Internet UP    -> Spotify: token refresh + stop/play, then skip track
#                  -> Radio: simple play retry with backoff
#                  -> Max retries: switch to recovery fallback station
#
# Silence timeout:
#   Only triggers AFTER recovery has given up (retries exhausted or
#   no recovery in progress). Switches to a separate silence fallback
#   which can be a radio station or Spotify playlist (shuffle/repeat).
#
# Startup auto-play:
#   After power cut, waits for internet then auto-starts a selected station.

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
    'description'  => 'Fancy-Dancy Stream Watchdog',
});

my $prefs = preferences('plugin.streamwatchdog');

$prefs->init({
    enabled                => 1,
    poll_interval          => 15,
    debounce_delay         => 10,
    max_retries            => 5,
    backoff_seconds        => 30,
    cooldown_minutes       => 10,
    freeze_threshold       => 30,
    fallback_enabled       => 1,
    fallback_url           => '',
    fallback_title         => '',
    ping_host              => '8.8.8.8',
    silence_enabled        => 1,
    silence_timeout        => 10,
    silence_fallback_url   => '',
    silence_fallback_title => '',
    silence_repeat         => 1,
    startup_enabled        => 1,
    startup_url            => '',
    startup_title          => '',
    startup_delay          => 30,
    startup_repeat         => 1,
});

my %playerState;    # per-player state tracking
my %watchdogAction; # flags for commands issued by watchdog itself

# ---------------------------------------------------------------------------
# Plugin initialisation
# ---------------------------------------------------------------------------
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

    Slim::Control::Request::subscribe(
        \&_onClientNew,
        [['client'], ['new', 'reconnect']]
    );

    _schedulePoll();

    $log->info("Stream Watchdog v2.0 initialised. Poll: "
        . $prefs->get('poll_interval') . "s, Freeze: "
        . $prefs->get('freeze_threshold') . "s, Recovery fallback: "
        . ($prefs->get('fallback_url') ? ($prefs->get('fallback_title') || 'set') : 'not set')
        . ", Silence fallback: "
        . ($prefs->get('silence_fallback_url') ? $prefs->get('silence_timeout') . "min" : 'not set')
        . ", Startup: "
        . ($prefs->get('startup_url') ? ($prefs->get('startup_title') || 'set') : 'not set'));
}

# ---------------------------------------------------------------------------
# Polling timer
# ---------------------------------------------------------------------------
sub _schedulePoll {
    Slim::Utils::Timers::killTimers(undef, \&_pollAllPlayers);
    Slim::Utils::Timers::setTimer(
        undef,
        time() + $prefs->get('poll_interval'),
        \&_pollAllPlayers
    );
}

# ---------------------------------------------------------------------------
# Internet connectivity check via ping
# ---------------------------------------------------------------------------
sub _internetUp {
    my $host   = $prefs->get('ping_host') || '8.8.8.8';
    my $result = system("ping -c 1 -W 3 $host >/dev/null 2>&1");
    return $result == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Command subscription: detect user vs watchdog initiated commands
# ---------------------------------------------------------------------------
sub _onPlayerCommand {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();
    my $cmd     = $request->getRequest(1) // '';

    if ($cmd eq 'play') {
        # Ignore plays issued by the watchdog itself
        if ($watchdogAction{$id}{play}) {
            $watchdogAction{$id}{play} = 0;
            $log->debug("[$id] Watchdog-issued play - preserving state");
            return;
        }
        # User started playback - full state reset
        $playerState{$id}{userStopped}            = 0;
        $playerState{$id}{retries}                = 0;
        $playerState{$id}{stopTime}               = undef;
        $playerState{$id}{cooldownUntil}          = 0;
        $playerState{$id}{lastPlayTime}           = time();
        $playerState{$id}{hangDetected}           = 0;
        $playerState{$id}{byteStall}              = 0;
        $playerState{$id}{lastTrackTime}          = undef;
        $playerState{$id}{lastTrackTimeSeen}      = undef;
        $playerState{$id}{lastBytesReceived}      = undef;
        $playerState{$id}{lastBytesReceivedSeen}  = undef;
        $playerState{$id}{waitingForInternet}     = 0;
        $playerState{$id}{usingFallback}          = 0;
        $playerState{$id}{silenceStart}           = undef;
        $playerState{$id}{silenceHandoverPending} = 0;
        $playerState{$id}{startupPending}         = 0;
        $playerState{$id}{startupDone}            = 1;
        _recordTrackInfo($client);
        $log->debug("[$id] User play - watchdog reset");

    } elsif ($cmd eq 'pause') {
        return if $watchdogAction{$id}{stop};
        $playerState{$id}{userStopped}  = 1;
        $playerState{$id}{hangDetected} = 0;
        $log->debug("[$id] User pause - watchdog suppressed");

    } elsif ($cmd eq 'stop' || $cmd eq 'clear') {
        if ($watchdogAction{$id}{stop}) {
            $watchdogAction{$id}{stop} = 0;
            $log->debug("[$id] Watchdog-issued stop - not suppressing recovery");
            return;
        }
        $playerState{$id}{userStopped}        = 1;
        $playerState{$id}{retries}            = 0;
        $playerState{$id}{hangDetected}       = 0;
        $playerState{$id}{byteStall}              = 0;
        $playerState{$id}{waitingForInternet}     = 0;
        $playerState{$id}{usingFallback}          = 0;
        $playerState{$id}{silenceHandoverPending} = 0;
        $log->debug("[$id] User stop/clear - watchdog suppressed");

    } elsif ($cmd eq 'index') {
        $playerState{$id}{userStopped}           = 0;
        $playerState{$id}{retries}               = 0;
        $playerState{$id}{stopTime}              = undef;
        $playerState{$id}{hangDetected}          = 0;
        $playerState{$id}{byteStall}             = 0;
        $playerState{$id}{lastTrackTime}         = undef;
        $playerState{$id}{lastTrackTimeSeen}     = undef;
        $playerState{$id}{lastBytesReceived}     = undef;
        $playerState{$id}{lastBytesReceivedSeen} = undef;
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
        $playerState{$id}{byteStall}          = 0;
        $playerState{$id}{waitingForInternet} = 0;
        $log->debug("[$id] Power off - watchdog suppressed");
    }
}

# ---------------------------------------------------------------------------
# Startup auto-play: fires when player connects after power cut
# ---------------------------------------------------------------------------
sub _onClientNew {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();
    my $event   = $request->getRequest(1) // '';

    return unless $prefs->get('startup_enabled');
    return unless $prefs->get('startup_url');

    # Only trigger if not already played this session
    unless ($playerState{$id}{startupDone}) {
        $log->info("[$id] Player $event - scheduling startup auto-play");
        $playerState{$id}{startupDone}    = 0;
        $playerState{$id}{startupPending} = 1;
        _checkStartupReady($client, 0);
    }
}

sub _checkStartupReady {
    my ($client, $attempts) = @_;
    my $id = $client->id();

    return unless $playerState{$id}{startupPending};

    # Cancel if already playing
    my $mode = Slim::Player::Source::playmode($client);
    if ($mode eq 'play') {
        $log->info("[$id] Already playing - startup cancelled");
        $playerState{$id}{startupPending} = 0;
        $playerState{$id}{startupDone}    = 1;
        return;
    }

    if (_internetUp()) {
        $log->info("[$id] Internet ready - startup play in " . $prefs->get('startup_delay') . "s");
        Slim::Utils::Timers::setTimer(
            $client,
            time() + ($prefs->get('startup_delay') || 30),
            \&_doStartupPlay
        );
    } elsif ($attempts < 20) {
        # Retry every 15s for up to 5 minutes
        $log->debug("[$id] Startup: waiting for internet (attempt $attempts)");
        Slim::Utils::Timers::setTimer(
            $client,
            time() + 15,
            sub {
                my $c = shift;
                return unless $c;
                _checkStartupReady($c, $attempts + 1);
            }
        );
    } else {
        $log->warn("[$id] Startup: internet unavailable after 5 min - giving up");
        $playerState{$id}{startupPending} = 0;
    }
}

sub _doStartupPlay {
    my $client = shift;
    my $id     = $client->id();

    return unless $playerState{$id}{startupPending};

    # Cancel if already playing
    my $mode = Slim::Player::Source::playmode($client);
    if ($mode eq 'play') {
        $log->info("[$id] Already playing - startup skipped");
        $playerState{$id}{startupPending} = 0;
        $playerState{$id}{startupDone}    = 1;
        return;
    }

    my $url    = $prefs->get('startup_url');
    my $title  = $prefs->get('startup_title') || 'Startup';
    my $repeat = $prefs->get('startup_repeat') // 1;

    $log->warn("[$id] Startup auto-play: $title");

    $client->execute(['playlist', 'clear']);
    $client->execute(['playlist', 'play', $url, $title]);

    if ($url =~ /spotify/i) {
        Slim::Utils::Timers::setTimer(
            $client, time() + 3,
            sub {
                my $c = shift;
                return unless $c;
                $c->execute(['playlist', 'shuffle', '1']);
                $c->execute(['playlist', 'repeat', '2']) if $repeat;
                $log->info("[" . $c->id() . "] Startup: shuffle + repeat set");
            }
        );
    }

    $playerState{$id}{startupPending}    = 0;
    $playerState{$id}{startupDone}       = 1;
    $playerState{$id}{lastPlayTime}      = time();
    $playerState{$id}{userStopped}       = 0;
    $playerState{$id}{silenceStart}      = undef;
}

# ---------------------------------------------------------------------------
# Record current track source info for recovery decisions
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------
sub _pollAllPlayers {
    _schedulePoll();
    return unless $prefs->get('enabled');
    for my $client (Slim::Player::Client::clients()) {
        next unless $client->isPlayer();
        _checkPlayer($client);
    }
}

# ---------------------------------------------------------------------------
# Check a single player
# ---------------------------------------------------------------------------
sub _checkPlayer {
    my $client = shift;
    my $id     = $client->id();

    return unless $client->power();

    my $mode = Slim::Player::Source::playmode($client);

    # Waiting for internet to restore (player stopped mid-outage)
    if ($playerState{$id}{waitingForInternet} && $mode ne 'play') {
        if (_internetUp()) {
            $log->info("[$id] Internet restored - resuming");
            $playerState{$id}{waitingForInternet}    = 0;
            $playerState{$id}{retries}               = 0;
            $playerState{$id}{stopTime}              = undef;
            $playerState{$id}{lastBytesReceived}     = undef;
            $playerState{$id}{lastBytesReceivedSeen} = undef;
            $watchdogAction{$id}{play}               = 1;
            $client->execute(['play']);
        } else {
            $log->debug("[$id] Still waiting for internet...");
        }
        return;
    }

    # Playing: check for hangs
    if ($mode eq 'play') {
        _checkForHang($client);
        return;
    }

    # Not playing: reset hang/byte tracking
    $playerState{$id}{hangDetected}          = 0;
    $playerState{$id}{byteStall}             = 0;
    $playerState{$id}{lastTrackTime}         = undef;
    $playerState{$id}{lastTrackTimeSeen}     = undef;
    $playerState{$id}{lastBytesReceived}     = undef;
    $playerState{$id}{lastBytesReceivedSeen} = undef;

    # Skip everything if user deliberately stopped
    return if $playerState{$id}{userStopped};
    return unless $playerState{$id}{lastPlayTime};

    # Cooldown after max retries
    my $cooldownUntil = $playerState{$id}{cooldownUntil} // 0;
    my $inCooldown    = time() < $cooldownUntil;

    # Recovery in progress: retries > 0 means we're actively trying to recover
    my $retries     = $playerState{$id}{retries} // 0;
    my $inRecovery  = $retries > 0;

    # --- Silence timeout ---
    # Only triggers when recovery has given up or no recovery needed
    # (i.e. not mid-recovery and not in cooldown)
    if ($prefs->get('silence_enabled') && $prefs->get('silence_fallback_url')) {
        if (!$inRecovery && !$inCooldown) {
            # Start silence timer only when not recovering
            unless ($playerState{$id}{silenceStart}) {
                $playerState{$id}{silenceStart} = time();
                $log->debug("[$id] Silence timer started");
            }

            my $silenceSeconds = time() - $playerState{$id}{silenceStart};
            my $timeoutSeconds = ($prefs->get('silence_timeout') || 10) * 60;

            if ($silenceSeconds >= $timeoutSeconds) {
                if (_internetUp()) {
                    my $silenceMinutes = int($silenceSeconds / 60);
                    $log->warn("[$id] Silence timeout after ${silenceMinutes} min - switching to silence fallback");
                    _switchToSilenceFallback($client);
                    return;
                }
            }
        } else {
            # Mid-recovery or cooldown: reset silence timer so it starts fresh
            # after recovery gives up
            $playerState{$id}{silenceStart} = undef;
            $log->debug("[$id] Silence timer reset (recovery in progress or cooldown)") if $inRecovery;
        }
    }

    # Cooldown: wait before retrying
    if ($inCooldown) {
        $log->debug("[$id] In cooldown");
        return;
    }

    # After cooldown: if silence handover was pending, hand over to silence timer
    if ($playerState{$id}{silenceHandoverPending}) {
        $log->info("[$id] Cooldown complete - handing over to silence timer");
        $playerState{$id}{silenceHandoverPending} = 0;
        $playerState{$id}{userStopped}            = 1;
        return;
    }

    # Debounce: wait briefly before acting on a fresh stop
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

# ---------------------------------------------------------------------------
# Hang detection: monitors track time and bytes while in play mode
# ---------------------------------------------------------------------------
sub _checkForHang {
    my $client = shift;
    my $id     = $client->id();

    # Handle internet wait state while in play mode
    if ($playerState{$id}{waitingForInternet}) {
        if (_internetUp()) {
            $log->info("[$id] Internet restored - resuming from hang");
            $playerState{$id}{waitingForInternet}    = 0;
            $playerState{$id}{retries}               = 0;
            $playerState{$id}{stopTime}              = undef;
            $playerState{$id}{lastTrackTime}         = undef;
            $playerState{$id}{lastTrackTimeSeen}     = undef;
            $playerState{$id}{lastBytesReceived}     = undef;
            $playerState{$id}{lastBytesReceivedSeen} = undef;
            $watchdogAction{$id}{play}               = 1;
            $client->execute(['play']);
        } else {
            $log->debug("[$id] Still waiting for internet...");
        }
        return;
    }

    my $currentTime = $client->controller()->playingSongElapsed() // 0;
    my $lastTime    = $playerState{$id}{lastTrackTime};
    my $lastSeen    = $playerState{$id}{lastTrackTimeSeen} // time();

    # Bytes received / buffer fullness (wrapped in eval for player compatibility)
    my $bytesReceived  = eval { $client->bytesReceived()  } // 0;
    my $bufferFullness = eval { $client->bufferFullness() } // 100;
    my $lastBytes      = $playerState{$id}{lastBytesReceived};
    my $lastBytesSeen  = $playerState{$id}{lastBytesReceivedSeen} // time();

    if (!defined $lastBytes) {
        $playerState{$id}{lastBytesReceived}     = $bytesReceived;
        $playerState{$id}{lastBytesReceivedSeen} = time();
    } elsif ($bytesReceived != $lastBytes) {
        $playerState{$id}{lastBytesReceived}     = $bytesReceived;
        $playerState{$id}{lastBytesReceivedSeen} = time();
        $playerState{$id}{byteStall}             = 0;
        $log->debug("[$id] Bytes flowing: $bytesReceived, buffer: $bufferFullness%");
    } else {
        my $bytesStallFor = time() - $lastBytesSeen;
        $log->debug("[$id] Bytes stalled: $bytesReceived for ${bytesStallFor}s, buffer: $bufferFullness%");

        if ($bytesStallFor >= $prefs->get('freeze_threshold') && $bufferFullness == 0) {
            my $cooldownUntil = $playerState{$id}{cooldownUntil} // 0;
            unless (time() < $cooldownUntil || $playerState{$id}{userStopped}) {
                $log->warn("[$id] BYTE STALL - no data for ${bytesStallFor}s, buffer empty");
                $playerState{$id}{byteStall}             = 1;
                $playerState{$id}{lastBytesReceived}     = undef;
                $playerState{$id}{lastBytesReceivedSeen} = undef;
                $playerState{$id}{lastTrackTime}         = undef;
                $playerState{$id}{lastTrackTimeSeen}     = undef;
                $playerState{$id}{stopTime}              = time() unless $playerState{$id}{stopTime};
                _attemptRecovery($client, 'byte stall');
                return;
            }
        }
    }

    # Track time monitoring
    if (!defined $lastTime) {
        $playerState{$id}{lastTrackTime}     = $currentTime;
        $playerState{$id}{lastTrackTimeSeen} = time();
        $playerState{$id}{lastPlayTime}      = time();
        $playerState{$id}{silenceStart}      = undef;
        _recordTrackInfo($client);
        $log->debug("[$id] Track time init: ${currentTime}s");
        return;
    }

    if ($currentTime != $lastTime) {
        # Track advancing normally - reset all failure flags
        $playerState{$id}{lastTrackTime}         = $currentTime;
        $playerState{$id}{lastTrackTimeSeen}     = time();
        $playerState{$id}{lastPlayTime}          = time();
        $playerState{$id}{hangDetected}          = 0;
        $playerState{$id}{byteStall}             = 0;
        $playerState{$id}{userStopped}           = 0;
        $playerState{$id}{waitingForInternet}    = 0;
        $playerState{$id}{silenceStart}          = undef;
        $playerState{$id}{stopTime}              = undef;
        _recordTrackInfo($client);
        $log->debug("[$id] Track advancing: ${currentTime}s, bytes: $bytesReceived");
        return;
    }

    # Track time frozen
    my $frozenFor = time() - $lastSeen;
    $log->debug("[$id] Track frozen at ${currentTime}s for ${frozenFor}s");

    if ($frozenFor >= $prefs->get('freeze_threshold')) {
        my $cooldownUntil = $playerState{$id}{cooldownUntil} // 0;
        return if time() < $cooldownUntil;
        return if $playerState{$id}{userStopped};

        $log->warn("[$id] HANG DETECTED - track frozen at ${currentTime}s for ${frozenFor}s");
        $playerState{$id}{hangDetected}      = 1;
        $playerState{$id}{lastTrackTime}     = undef;
        $playerState{$id}{lastTrackTimeSeen} = undef;
        $playerState{$id}{stopTime}          = time() unless $playerState{$id}{stopTime};
        _attemptRecovery($client, 'hang');
    }
}

# ---------------------------------------------------------------------------
# Recovery dispatcher
# ---------------------------------------------------------------------------
sub _attemptRecovery {
    my ($client, $reason) = @_;
    my $id         = $client->id();
    my $retries    = $playerState{$id}{retries} // 0;
    my $maxRetries = $prefs->get('max_retries');
    my $source     = $playerState{$id}{sourceType} // 'unknown';

    unless (_internetUp()) {
        $playerState{$id}{waitingForInternet} = 1;
        $log->warn("[$id] Internet DOWN - waiting (reason: $reason)");
        return;
    }

    $log->info("[$id] Internet UP - recovering (reason: $reason, source: $source)");

    if ($retries >= $maxRetries) {
        # Check if we're already on the fallback and it has also failed
        if ($playerState{$id}{usingFallback}) {
            # Fallback itself has failed - enter cooldown and let silence timer take over
            my $cooldownSecs = $prefs->get('cooldown_minutes') * 60;
            $playerState{$id}{cooldownUntil}  = time() + $cooldownSecs;
            $playerState{$id}{retries}        = 0;
            $playerState{$id}{stopTime}       = undef;
            $playerState{$id}{usingFallback}  = 0;
            $log->warn("[$id] Fallback also failed - cooling down "
                . $prefs->get('cooldown_minutes') . "min then silence timer will take over");
            return;
        }

        if ($prefs->get('fallback_enabled') && $prefs->get('fallback_url')) {
            _switchToFallback($client);
        } else {
            # No fallback configured - enter one cooldown cycle then
            # set userStopped so silence timer can take over
            my $cooldownSecs = $prefs->get('cooldown_minutes') * 60;
            $playerState{$id}{cooldownUntil}       = time() + $cooldownSecs;
            $playerState{$id}{retries}             = 0;
            $playerState{$id}{stopTime}            = undef;
            $playerState{$id}{silenceHandoverPending} = 1;
            $log->warn("[$id] Max retries - no fallback - cooling down "
                . $prefs->get('cooldown_minutes') . "min then handing over to silence timer");
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

# ---------------------------------------------------------------------------
# Recovery fallback: after max retries, play a radio station
# ---------------------------------------------------------------------------
sub _switchToFallback {
    my $client = shift;
    my $id     = $client->id();
    my $url    = $prefs->get('fallback_url');
    my $title  = $prefs->get('fallback_title') || 'Fallback Radio';

    $log->warn("[$id] Recovery fallback: $title");

    $client->execute(['playlist', 'clear']);
    $client->execute(['playlist', 'play', $url, $title]);

    $playerState{$id}{usingFallback}      = 1;
    $playerState{$id}{retries}            = 0;
    $playerState{$id}{stopTime}           = undef;
    $playerState{$id}{userStopped}        = 0;
    $playerState{$id}{waitingForInternet} = 0;
    $playerState{$id}{silenceStart}       = undef;
    $playerState{$id}{sourceType}         = 'radio';
}

# ---------------------------------------------------------------------------
# Silence fallback: after prolonged silence, play radio or Spotify playlist
# ---------------------------------------------------------------------------
sub _switchToSilenceFallback {
    my $client = shift;
    my $id     = $client->id();
    my $url    = $prefs->get('silence_fallback_url');
    my $title  = $prefs->get('silence_fallback_title') || 'Silence Fallback';
    my $repeat = $prefs->get('silence_repeat') // 1;

    $log->warn("[$id] Silence fallback: $title");

    $client->execute(['playlist', 'clear']);
    $client->execute(['playlist', 'play', $url, $title]);

    if ($url =~ /spotify/i) {
        Slim::Utils::Timers::setTimer(
            $client, time() + 3,
            sub {
                my $c = shift;
                return unless $c;
                $c->execute(['playlist', 'shuffle', '1']);
                if ($repeat) {
                    $c->execute(['playlist', 'repeat', '2']);
                    $log->info("[" . $c->id() . "] Silence fallback: shuffle + repeat");
                } else {
                    $log->info("[" . $c->id() . "] Silence fallback: shuffle only");
                }
            }
        );
    }

    $playerState{$id}{silenceStart}          = undef;
    $playerState{$id}{userStopped}           = 0;
    $playerState{$id}{retries}               = 0;
    $playerState{$id}{stopTime}              = undef;
    $playerState{$id}{waitingForInternet}    = 0;
    $playerState{$id}{usingFallback}         = 1;
    $playerState{$id}{lastBytesReceived}     = undef;
    $playerState{$id}{lastBytesReceivedSeen} = undef;
}

# ---------------------------------------------------------------------------
# Spotify recovery: token refresh + stop/play, then track skip
# ---------------------------------------------------------------------------
sub _recoverSpotify {
    my $client  = shift;
    my $id      = $client->id();
    my $retries = $playerState{$id}{retries} // 1;

    $log->info("[$id] Spotify recovery attempt $retries");

    my $playlistSize = Slim::Player::Playlist::count($client) // 0;
    my $currentIndex = Slim::Player::Source::streamingSongIndex($client) // 0;

    if ($retries <= 2) {
        $log->info("[$id] Spotify: token refresh + stop/play");
        eval { $client->execute(['spotty', 'refresh']); };
        $log->warn("[$id] Spotty refresh failed: $@") if $@;

        Slim::Utils::Timers::setTimer(
            $client, time() + 3,
            sub {
                my $c = shift;
                return unless $c;
                my $cid = $c->id();
                $log->info("[$cid] Spotify: stop");
                $watchdogAction{$cid}{stop} = 1;
                $c->execute(['stop']);
                Slim::Utils::Timers::setTimer(
                    $c, time() + 2,
                    sub {
                        my $c2 = shift;
                        return unless $c2;
                        my $cid2 = $c2->id();
                        $log->info("[$cid2] Spotify: play after stop");
                        $watchdogAction{$cid2}{play} = 1;
                        $c2->execute(['play']);
                    }
                );
            }
        );
    } else {
        $log->info("[$id] Spotify: skip track (attempt $retries)");
        if ($playlistSize > 1 && $currentIndex < $playlistSize - 1) {
            $client->execute(['playlist', 'index', '+1']);
            $log->info("[$id] Skipped to " . ($currentIndex + 2) . "/$playlistSize");
        } else {
            $log->info("[$id] Restarting playlist from track 1");
            $client->execute(['playlist', 'index', '0']);
            Slim::Utils::Timers::setTimer(
                $client, time() + 1,
                sub {
                    my $c = shift;
                    return unless $c;
                    $watchdogAction{$c->id()}{play} = 1;
                    $c->execute(['play']);
                }
            );
        }
    }
}

# ---------------------------------------------------------------------------
# Radio recovery
# ---------------------------------------------------------------------------
sub _recoverRadio {
    my $client = shift;
    my $id     = $client->id();
    $log->info("[$id] Radio recovery: play");
    $client->execute(['play']);
}

# ---------------------------------------------------------------------------
# Generic recovery
# ---------------------------------------------------------------------------
sub _recoverGeneric {
    my $client = shift;
    my $id     = $client->id();
    $log->info("[$id] Generic recovery: play");
    $client->execute(['play']);
}

# ---------------------------------------------------------------------------
# Read LMS Favourites from OPML file for settings page dropdown
# ---------------------------------------------------------------------------
sub getFavourites {
    my $favs     = [];
    my $opmlFile = Slim::Utils::Prefs::dir() . "/favorites.opml";

    unless (-f $opmlFile) {
        $log->warn("Favourites OPML not found: $opmlFile");
        return $favs;
    }

    open(my $fh, '<', $opmlFile) or do {
        $log->warn("Cannot open favourites: $!");
        return $favs;
    };

    while (my $line = <$fh>) {
        if ($line =~ /URL="([^"]+)"[^>]*text="([^"]+)"/) {
            my ($url, $title) = ($1, $2);
            push @{$favs}, { id => $url, title => $title };
            $log->debug("Favourite: $title");
        }
    }
    close($fh);

    $log->info("Favourites: " . scalar(@{$favs}) . " items");
    return $favs;
}

sub getDisplayName { 'PLUGIN_STREAMWATCHDOG_NAME' }
sub playerMenu     { undef }

1;
