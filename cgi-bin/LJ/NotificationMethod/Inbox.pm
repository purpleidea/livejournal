package LJ::NotificationMethod::Inbox;

use strict;
use Carp qw/ croak /;
use base 'LJ::NotificationMethod';
use Class::Autouse qw(LJ::NotificationInbox);

sub can_digest { 1 };

# takes a $u, and $journalid
sub new {
    my $class = shift;

    croak "no args passed"
        unless @_;

    my $u = shift;
    croak "invalid user object passed"
        unless LJ::isu($u);

    my $journalid = shift;

    my $self = {
        u => $u,
        journalid => $journalid,
    };

    return bless $self, $class;
}

sub title { LJ::Lang::ml('notification_method.inbox.title') }

sub new_from_subscription {
    my $class = shift;
    my $subscr = shift;

    return $class->new($subscr->owner, $subscr->journalid);
}

sub u {
    my $self = shift;
    croak "'u' is an object method"
        unless ref $self eq __PACKAGE__;

    if (my $u = shift) {
        croak "invalid 'u' passed to setter"
            unless LJ::isu($u);

        $self->{u} = $u;
    }
    croak "superfluous extra parameters"
        if @_;

    return $self->{u};
}

# notify a single event
sub notify {
    my $self = shift;
    my $opts = shift || {};

    croak "'notify' is an object method"
        unless ref $self eq __PACKAGE__;

    my $u = $self->u;

    my @events = @_;
    croak "'notify' requires one or more events"
        unless @events;

    my $q = LJ::NotificationInbox->new($u)
        or die "Could not get notification queue for user $u->{user}";

    foreach my $ev (@events) {
        croak "invalid event passed" unless ref $ev;

        $q->enqueue(event => $ev);
    }

    # widget reset
    my $cache_friends_update_key  = "friend_updates:" . $u->userid;
    LJ::MemCache::delete($cache_friends_update_key);

    my $cache_update_for_user     = "update_for_users:" . $u->userid;
    LJ::MemCache::delete($cache_update_for_user);

    # widget "updates for user" on new homepage
    my $updates_for_user          = "updates_for_user:" . $u->userid;
    LJ::MemCache::delete($updates_for_user);
    
    return 1;
}

sub configured { 1 }
sub configured_for_user { 1 } # always configured for all users

1;
