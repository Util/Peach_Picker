#!/usr/bin/perl
use strict;
use warnings;
use Storable;
#use Data::Dumper; $Data::Dumper::Useqq = 1;


=head1 NAME

peach_picker - An bot for small, project-based or group-run IRC channels.

=head1 VERSION

Version 0.11

=cut

our $VERSION = '0.11';


=begin comments

If anyone wants to play with this, just make up a channel name and a bot name for use while testing.

=end comments

=cut

#CHANNELS      => [ '#atlanta.pm_test', '#atlanta.pm' ],
use constant {
    BOT_NICK      => 'opbot_Atlanta',
    BOT_OWNER     => 'Util <bruce.gray@acm.org>',
    IRC_SERVER    => 'irc.perl.org',
    CHANNELS      => [ '#atlanta.pm_test' ],
    SEEN_FILE     => 'opbot_seen.dat',
    LOG_DIR       => 'opbot_logs',
    SAVE_INTERVAL => 20 * 60,                   # Save state every 20 mins
};

# XXX Make this an external config file! Check for it having been touched since last CHECK_INTERVAL, and reload if so.
my $nick_file = 'nicks.txt';
my %nick_to_auto_op;
if ( not -e $nick_file ) {
    print "Warning: Nick config file '$nick_file' not found; skipping\n";
}
else {
    open my $fh, '<', $nick_file
        or die;
    my @lines = <$fh>;
    close $fh or warn;
    chomp @lines;
    # XXX Add code to supress comment lines.
    %nick_to_auto_op = map { $_ => 1 } @lines;
}

use POE qw(
    Component::IRC::State
    Component::IRC::Plugin::Logger
    Component::IRC::Plugin::AutoJoin
    Component::IRC::Plugin::BotCommand
    Component::IRC::Plugin::CycleEmpty
    Component::IRC::Plugin::CTCP
);
use POE::Component::IRC::Common qw( parse_user l_irc );

my @irc_states = qw( join part public quit ctcp_action botcmd_seen );
my @poe_states = ( '_start', 'save', map { 'irc_' . $_ } @irc_states );


my $SEEN = ( -s SEEN_FILE ) ? retrieve(SEEN_FILE) : {};

{
    my $irc = POE::Component::IRC::State->spawn(
        Server  => IRC_SERVER,
        Nick    => BOT_NICK,
        Ircname => BOT_OWNER,
# XXX Play with this - it is from http://search.cpan.org/~tbr/POE-Component-IRC-Plugin-Trac-RSS-0.11/lib/POE/Component/IRC/Plugin/Trac/RSS.pm
#        Debug        => 0,
#        Plugin_debug => 1,
#        Options      => { trace => 0 },
    ) or die;

    # This is so we can see when a start-up is hung by network downtime.
    print "IRC connection spawned\n";

    POE::Session->create(
        heap            => { irc  => $irc },
        package_states  => [ main => \@poe_states ],
#        options         => { trace => 1, debug => 1 },
    );

    $poe_kernel->run();
}


sub _start {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    my $irc = $heap->{irc};

    $irc->plugin_add( CTCP       => POE::Component::IRC::Plugin::CTCP->new( ) );
    $irc->plugin_add( Logger     => POE::Component::IRC::Plugin::Logger->new(     Path     => LOG_DIR ) );
    $irc->plugin_add( AutoJoin   => POE::Component::IRC::Plugin::AutoJoin->new(   Channels => CHANNELS ) );
    $irc->plugin_add( BotCommand => POE::Component::IRC::Plugin::BotCommand->new( Commands => { seen => 'Usage: seen <nick>' } ) );
    $irc->plugin_add( CycleEmpty => POE::Component::IRC::Plugin::CycleEmpty->new( ) );

    $irc->yield( register => @irc_states );
    $irc->yield('connect');
    $kernel->delay_set( 'save', SAVE_INTERVAL );

    return;
}

sub save {
    my $kernel = $_[KERNEL];

    warn "storing\n";
    store( $SEEN, SEEN_FILE )
      or die "Can't save state";

    $kernel->delay_set( 'save', SAVE_INTERVAL );
}

sub irc_ctcp_action {
    my ( $nick, $channel_aref, $text ) = @_[ ARG0 .. $#_ ];

    my $channel = $channel_aref->[0];

    my $nick_parsed = parse_user($nick);
    _add_nick( $nick, "on $channel doing: * $nick_parsed $text" );
}

sub irc_join {
    my ( $kernel, $heap, $nick, $channel ) = @_[ KERNEL, HEAP, ARG0 .. $#_ ];

    my $nick_parsed = parse_user($nick);

    if ( $nick_parsed eq BOT_NICK ) {
        warn "Ignore my own joining of a channel.\n";
        return;
    }
    if ( !$nick_to_auto_op{$nick_parsed} ) {
        warn "Not op-ing $nick_parsed - not in authorized list\n";
        return;
    }

    my $irc = $heap->{irc};
    my $bot_op  = $irc->is_channel_operator( $channel, BOT_NICK );
    my $user_op = $irc->is_channel_operator( $channel, $nick );

    if ( !$bot_op ) {
        warn "irc_join - can't op - Bot is not a channel op\n";
    }
    elsif ( $user_op ) {
        warn "irc_join - won't op - User joined, and is somehow already a channel op (maybe due to another bot?)\n";
    }
    else {
        # Definitely use $nick_parsed to change mode; don't use unparsed $nick.
        $irc->yield( mode => $channel => '+o' => $nick_parsed );
        warn "$channel => '+o' => $nick_parsed\n";
    }

    _add_nick( $nick, "joining $channel" );
}

sub irc_part {
    my ( $nick, $channel, $text ) = @_[ ARG0 .. $#_ ];

    my $msg = "parting $channel";
    $msg .= " with message '$text'" if defined $text;

    _add_nick( $nick, $msg );
}

sub irc_public {
    my ( $nick, $channel_aref, $text ) = @_[ ARG0 .. $#_ ];
    my $channel = $channel_aref->[0];

    _add_nick( $nick, "on $channel saying: $text" );
}

sub irc_quit {
    my ( $nick, $text ) = @_[ ARG0 .. $#_ ];

    my $msg = 'quitting';
    $msg .= " with message '$text'" if defined $text;

    _add_nick( $nick, $msg );
}

sub _add_nick {
    my ( $nick, $msg ) = @_;
    my $nick_parsed = parse_user($nick);

    $SEEN->{ l_irc($nick_parsed) } = {
        LAST_SEEN_DATE => time,
        LAST_SEEN_MSG  => $msg,
    };
}

sub irc_botcmd_seen {
    my ( $heap, $nick, $channel, $target ) = @_[ HEAP, ARG0 .. $#_ ];

    my $privmsg;
    if ( my $target_href = $SEEN->{ l_irc($target) } ) {
        my $time = $target_href->{LAST_SEEN_DATE};
        my $msg  = $target_href->{LAST_SEEN_MSG};
        my $date = localtime $time;
        $privmsg = "I last saw $target at $date, $msg";
    }
    else {
        $privmsg = "I haven't seen $target";
    }

    my $irc         = $heap->{irc};
    my $nick_parsed = parse_user($nick);

    $irc->yield( privmsg => $channel, "$nick_parsed: $privmsg" );
}

__END__
XX Fix all this!

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Foo::Bar;

    my $foo = Foo::Bar->new();
    ...

=head1 AUTHOR

Bruce Gray, C<< <bruce.gray at acm.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-foo-bar at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Foo-Bar>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Foo::Bar


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Foo-Bar>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Foo-Bar>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Foo-Bar>

=item * Search CPAN

L<http://search.cpan.org/dist/Foo-Bar/>

=back


=head1 TODO

XXX Scan for XXX

XXX Document - usage

XXX Move to GitHub

XXX Rename

let seen work with public, too

This version hoists spawn() out of _start().

Try POE::Component::IRC::Plugin::Console

Features - channel recovery, Seen, auto-op, logging. No karma yet

XXX Does CTCP action still work?

Enumerate ACKNOWLEDGEMENTS

Fix BUGS and SUPPORT sections

Extract most code into new POE::Component::IRC::Plugin:: modules, and contribute to CPAN.

Add tests based on IO::Socket::INET.

Add options (for testing) to select channels, and auth user lists.

Document that this does not work well on servers that do not enforce ircnick registration.

Add support for RSS feeds from our googlecode project

TODO:
Add user info to this message:
    irc_join - can't op - Bot is not a channel op
Add a "Ops recovered" message
Status messages to console about which chanels we are in, etc?
Command-line script to dump opbot_seen.dat?
    perl -MStorable -wle '%h = %{retrieve(shift)}; printf "%-15s\t%s\t%s\n", $_, scalar(localtime $h{$_}{LAST_SEEN_DATE}), $h{$_}{LAST_SEEN_MSG} for sort keys %h;' opbot_seen.dat

Need to store SEEN info on a per-channel basis


=head1 ACKNOWLEDGEMENTS

All the IRCing members of Atlanta.pm L<http://atlanta.pm.org/>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Bruce Gray.

This program is free software; you can redistribute it and/or
modify it under the terms of either:

=over 4

=item * the GNU General Public License as published by the Free
Software Foundation; either version 1, or (at your option) any
later version, or

=item * the Artistic License version 2.0.

=back

=cut
