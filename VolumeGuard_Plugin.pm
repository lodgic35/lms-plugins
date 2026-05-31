package Plugins::VolumeGuard::Plugin;

# VolumeGuard - LMS Plugin v1.0
# Locks volume to a predefined level on selected players.
# Volume control is disabled (any change is immediately reverted).
# Toggle on/off from the settings page.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Player::Client;
use Slim::Control::Request;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.volumeguard',
    'defaultLevel' => 'INFO',
    'description'  => 'Volume Guard',
});

my $prefs = preferences('plugin.volumeguard');

$prefs->init({
    enabled         => 1,
    locked_volume   => 50,
    locked_players  => {},
});

my %guardAction; # flags for volume changes issued by the plugin itself

# ---------------------------------------------------------------------------
# Plugin initialisation
# ---------------------------------------------------------------------------
sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Plugins::VolumeGuard::Settings;
    Plugins::VolumeGuard::Settings->new($class);

    # Subscribe to volume/mixer changes
    Slim::Control::Request::subscribe(
        \&_onMixerChange,
        [['mixer'], ['volume']]
    );

    # Subscribe to new player connections - enforce volume on connect
    Slim::Control::Request::subscribe(
        \&_onClientNew,
        [['client'], ['new', 'reconnect']]
    );

    # Set initial volume on all locked players at startup
    Slim::Utils::Timers::setTimer(
        undef,
        Time::HiRes::time() + 5,
        \&_enforceAllPlayers
    );

    $log->info("Volume Guard v1.0 initialised. Locked volume: "
        . $prefs->get('locked_volume') . "%");
}

# ---------------------------------------------------------------------------
# Called whenever volume changes on any player
# ---------------------------------------------------------------------------
sub _onMixerChange {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();

    return unless $prefs->get('enabled');

    # Check if this player is locked
    my $lockedPlayers = $prefs->get('locked_players') || {};
    return unless $lockedPlayers->{$id};

    # If this change was issued by the plugin itself, ignore it
    if ($guardAction{$id}) {
        $guardAction{$id} = 0;
        $log->debug("[$id] Volume Guard issued this change - ignoring");
        return;
    }

    # Revert to locked volume
    my $lockedVol  = $prefs->get('locked_volume') // 50;
    my $currentVol = $client->volume() // 0;

    if ($currentVol != $lockedVol) {
        $log->info("[$id] Volume changed to $currentVol - reverting to $lockedVol");
        $guardAction{$id} = 1;
        $client->execute(['mixer', 'volume', $lockedVol]);
    }
}

# ---------------------------------------------------------------------------
# Called when a player connects - enforce locked volume immediately
# ---------------------------------------------------------------------------
sub _onClientNew {
    my $request = shift;
    my $client  = $request->client() or return;
    my $id      = $client->id();

    return unless $prefs->get('enabled');

    my $lockedPlayers = $prefs->get('locked_players') || {};
    return unless $lockedPlayers->{$id};

    # Short delay to let player fully connect
    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + 3,
        sub {
            my $c = shift;
            return unless $c;
            _enforceVolume($c);
        }
    );
}

# ---------------------------------------------------------------------------
# Enforce locked volume on a single player
# ---------------------------------------------------------------------------
sub _enforceVolume {
    my $client = shift;
    my $id     = $client->id();

    return unless $prefs->get('enabled');

    my $lockedPlayers = $prefs->get('locked_players') || {};
    return unless $lockedPlayers->{$id};

    my $lockedVol  = $prefs->get('locked_volume') // 50;
    my $currentVol = $client->volume() // 0;

    if ($currentVol != $lockedVol) {
        $log->info("[$id] Enforcing locked volume: $currentVol -> $lockedVol");
        $guardAction{$id} = 1;
        $client->execute(['mixer', 'volume', $lockedVol]);
    } else {
        $log->debug("[$id] Volume already at locked level: $lockedVol");
    }
}

# ---------------------------------------------------------------------------
# Enforce locked volume on all locked players
# ---------------------------------------------------------------------------
sub _enforceAllPlayers {
    return unless $prefs->get('enabled');

    my $lockedPlayers = $prefs->get('locked_players') || {};

    for my $client (Slim::Player::Client::clients()) {
        next unless $client->isPlayer();
        next unless $lockedPlayers->{$client->id()};
        _enforceVolume($client);
    }
}

# ---------------------------------------------------------------------------
# Called from settings when lock toggled or volume changed - re-enforce
# ---------------------------------------------------------------------------
sub applySettings {
    _enforceAllPlayers();
}

# ---------------------------------------------------------------------------
# Get all connected players for settings page
# ---------------------------------------------------------------------------
sub getPlayers {
    my @players;
    for my $client (Slim::Player::Client::clients()) {
        next unless $client->isPlayer();
        push @players, {
            id   => $client->id(),
            name => $client->name() || $client->id(),
        };
    }
    return \@players;
}

sub getDisplayName { 'PLUGIN_VOLUMEGUARD' }
sub playerMenu     { undef }

1;
