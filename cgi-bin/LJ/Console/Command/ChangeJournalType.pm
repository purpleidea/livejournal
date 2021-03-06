package LJ::Console::Command::ChangeJournalType;

use strict;
use base qw(LJ::Console::Command);
use Carp qw(croak);

sub cmd { "change_journal_type" }

sub desc { "Change a journal's type." }

sub args_desc { [
                 'journal' => "The username of the journal that type is changing.",
                 'type' => "Either 'person', 'community', or 'news'.",
                 'owner' => "The person to become the maintainer of the community/news journal. If changing to type 'person', the account will adopt the email address and password of the owner.",
                 'force' => "Specify this to create a community from a non-empty journal. The maintainer of the community will be the owner of the journal's entries (optional).",
                 'reason' => "Why you are changing journal type (optional).",
                 ] }

sub usage { '<journal> <type> <owner> [ force ] [ <reason> ]' }

sub can_execute {
    my $remote = LJ::get_remote();
    return LJ::check_priv($remote, "changejournaltype") || $LJ::IS_DEV_SERVER;
}

sub execute {
    my ($self, $user, $type, $owner, @args) = @_;
    my $remote = LJ::get_remote();

    return $self->error("This command takes three mandatory arguments. Consult the reference.")
        unless $user && $type && $owner;

    return $self->error("Keyword 'force' can be used only with type community.")
        if @args >= 1 and $args[0] eq 'force' and $type ne 'community';

    return $self->error("Type argument must be 'person', 'community', or 'news'.")
        unless $type =~ /^(?:person|community|news)$/;

    my $u = LJ::load_user($user);
    return $self->error("Invalid user: $user")
        unless $u;

    return $self->error("Account cannot be converted while not active.")
        unless $u->is_visible;

    return $self->error("Account is not a personal, community, or news journal.")
        unless $u->journaltype =~ /[PCN]/;

    return $self->error("You cannot convert your own account.")
        if LJ::u_equals($remote, $u);

    my $typemap = { 'community' => 'C', 'person' => 'P', 'news' => 'N' };
    return $self->error("This account is already a $type account")
        if $u->journaltype eq $typemap->{$type};

    my $ou = LJ::load_user($owner);
    return $self->error("Invalid username '$owner' specified as owner.")
        unless $ou;
    return $self->error("Owner must be a personal journal.")
        unless $ou->is_person;
    return $self->error("Owner must be an active account.")
        unless $ou->is_visible;
    return $self->error("Owner email address isn't validated.")
        unless $ou->is_validated;

    my $force;
    if ( @args and $args[0] eq 'force' ) {
        $force = 1;
        shift @args;
    }

    my $dbh = LJ::get_db_writer();

    LJ::MemCache::delete('u:s:' .  $u->userid) if $u;
    #############################
    # going to a personal journal. do they have any entries posted by other users?
    if ($type eq "person") {
        my $dbcr = LJ::get_cluster_def_reader($u);
        my $count = $dbcr->selectrow_array('SELECT COUNT(*) FROM log2 WHERE journalid = ? AND posterid <> journalid',
                                           undef, $u->id);

        return $self->error("Account contains $count entries posted by other users and cannot be converted.")
            if $count;

    # going to a community, shared, news. do they have any entries posted by themselves?
    # if so, make the new owner of the community to be the owner of these entries
    } else {
        my $dbcr = LJ::get_cluster_def_reader($u);
        my $count = $dbcr->selectrow_array('SELECT COUNT(*) FROM log2 WHERE journalid = ? AND posterid = journalid',
                                           undef, $u->id);
        if ($count) {
            if ($force) {
                $u->do("UPDATE log2 SET posterid = ? WHERE journalid = ? AND posterid = journalid", undef, $ou->id, $u->id)
                    or return $self->error($DBI::errstr);
                $self->info("$count entries of user '$u->{user}' belong to '$ou->{user}' now");
            } else {
                return $self->error("Account contains $count entries posted by the account itself. Use 'force' option if you want to convert it anyway.");
            }
        }
    }

    #############################
    # update the 'community' row, as necessary.
    if ($type eq "community") {
        $dbh->do("INSERT INTO community VALUES (?, 'open', 'members')", undef, $u->id);
    } else {
        $dbh->do("DELETE FROM community WHERE userid = ?", undef, $u->id);
    }

    #############################
    # delete friend-ofs if we're changing to a person account. otherwise
    # the owner can log in and read those users' entries.
    if ($type eq "person") {
        $u->remove_all_friendofs();
        $u->remove_all_subscribers();
    }

    #############################
    # clear out relations as necessary
    if ($type eq "person") {
        LJ::clear_rel($u, '*', $_) foreach qw(N M A P);

    # give the owner access
    } else {
        LJ::set_rel_multi( [$u->id, $ou->id, 'S'], [$u->id, $ou->id, 'P'] );
    }

    if (LJ::is_enabled('new_friends_and_subscriptions')) {
        if ($type eq 'news') {
            if ($u->is_personal) {
                if (my $friends = $u->friends(force => 1)) {
                    foreach my $friend (values %$friends) {
                        $friend->subscribe_to_user($u);
                        $u->remove_friend($friend);
                    }
                }
            }

            if ($u->is_community) {
                if (my $members = $u->members(force => 1)) {
                    foreach my $member (values %$members) {
                        $member->subscribe_to_user($u);
                        LJ::leave_community($member, $u);
                    }
                }
            }
        }

        if ($type eq 'person') {
            if ($u->is_community) {
                if (my $members = $u->members(force => 1)) {
                    foreach my $member (values %$members) {
                        warn $member->user;
                        $member->subscribe_to_user($u);
                        LJ::leave_community($member, $u);
                    }
                }
            }
        }

        if ($type eq 'community') {
            if ($u->is_personal) {
                if (my $friends = $u->friends(force => 1)) {
                    foreach my $friend (values %$friends) {
                        $friend->subscribe_to_user($u);
                        LJ::join_community($friend, $u);
                    }
                }
            }
        }
    }

    LJ::run_hook("change_journal_type", $u);

    #############################
    # update the user info
    my %extra = ();  # aggregates all the changes we're making

    # reset the email address
    $extra{email} = $ou->email_raw;
    $extra{status} = 'A';

    # TODO: move this to LJ::User::InfoHistory or change it to adding a new
    # entry; updating table with log data is not a good idea
    $dbh->do("UPDATE infohistory SET what='emailreset' WHERE userid=? AND what='email'", undef, $u->id)
        or $self->error("Error updating infohistory for emailreset: " . $dbh->errstr);

    # record only if it changed
    if ( $ou->email_raw ne $u->email_raw ) {
        LJ::User::InfoHistory->add($u, 'emailreset', $u->email_raw, $u->email_status);
    }

    # get the new journaltype
    $extra{journaltype} = $typemap->{$type};

    # we have update!
    LJ::update_user($u, { %extra });

    # update the password
    if ($type eq "community") {
        LJ::User::InfoHistory->add($u, 'password', $u->digest_of_password_change);
        $u->set_password('');
    }
    else {
        unless ($u->has_the_same_password_as($ou)) {
            LJ::User::InfoHistory->add($u, 'password', $u->digest_of_password_change);
            $u->copy_password_from($ou);
        }
    }

    # journaltype, birthday changed
    $u->invalidate_directory_record;
    $u->set_next_birthday;
    $u->lazy_interests_cleanup;

    #############################
    # register this action in statushistory
    my $msg = "account '" . $u->user . "' converted to $type";
    $msg = " (owner/parent is '" . $ou->user . "')";
    my $reason = '';
    $reason = join ' ', '. Reason:', @args if @args;
    LJ::statushistory_add($u, $remote, "change_journal_type", $msg. $reason);

    return $self->print("User " . $u->user . " converted to a $type account". $reason);
}

1;
