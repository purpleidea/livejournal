package LJ::Console::Command::Priv;

use strict;
use base qw(LJ::Console::Command);
use Carp qw(croak);

sub cmd { "priv" }

sub desc { "Grant or revoke user privileges." }

sub args_desc { [
                 'action'    => "'grant', 'revoke', or 'revoke_all' to revoke all args for a given priv",
                 'privs'     => "Comma-delimited list of priv names, priv:arg pairs, or package names (prefixed with #)",
                 'usernames' => "Comma-delimited list of usernames",
                 ] }

sub usage { '<action> <privs> <usernames>' }

sub can_execute {
    my $remote = LJ::get_remote();
    return LJ::check_priv($remote, "admin") || $LJ::IS_DEV_SERVER;
}

sub remote_can_grant {
    my ($remote, $priv, $arg) = @_;
    return 1 if LJ::check_priv($remote, 'admin', $priv) || 
                LJ::check_priv($remote, 'admin', '*') || 
                LJ::check_priv($remote, 'admin', "$priv/$arg");

    if (LJ::check_priv($remote, 'admin', '#')) {
        return 0 if $LJ::SENSITIVE_PRIVILEGES{$priv} || 
                    $LJ::SENSITIVE_PRIVILEGES{"$priv:$arg"};
        $arg =~ s/^admin\///;
        return 0 if $priv eq 'admin' && 
                    $LJ::SENSITIVE_PRIVILEGES{$arg};
        return 1;
    }
    return 0;
}

sub execute {
    my ($self, $action, $privs, $usernames, @args) = @_;

    return $self->error("This command takes three arguments. Consult the reference.")
        unless $action && $privs && $usernames && scalar(@args) == 0;

    return $self->error("Action must be one of 'grant', 'revoke', or 'revoke_all'")
        unless $action =~ /(?:grant|revoke|revoke\_all)/;

    my @users = split /,/, $usernames;
    my $dbh = LJ::get_db_reader();

    my @privs;
    foreach my $priv (split /,/, $privs) {
        if ($priv !~ /^#/) {
            push @privs, [ split /:/, $priv, 2 ];
        } else {
            # now we have a priv package
            my $pname = substr($priv, 1);
            my $privs = $dbh->selectall_arrayref("SELECT c.privname, c.privarg "
                                                 . "FROM priv_packages p, priv_packages_content c "
                                                 . "WHERE c.pkgid = p.pkgid AND p.name = ?", undef, $pname);
            push @privs, [ @$_ ] foreach @{$privs || []};
        }
    }

    return $self->error("No privs or priv packages specified")
        unless @privs;

    my $remote = LJ::get_remote();
    foreach my $pair (@privs) {
        my ($priv, $arg) = @$pair;
        unless ( remote_can_grant($remote, $priv, $arg) ) {
            $self->error("You are not permitted to $action $priv:$arg");
            next;
        }

        # To reduce likelihood that someone will do 'priv revoke foo'
        # intending to remove 'foo:*' and accidentally only remove 'foo:'
        if ($action eq "revoke" and not defined $arg) {
            $self->error("You must explicitly specify an empty argument when revoking a priv.");
            $self->error("For example, specify 'revoke foo:', not 'revoke foo', to revoke 'foo' with no argument.");
            next;
        }

        if ($action eq "revoke_all" and defined $arg) {
            $self->error("Do not explicitly specify priv arguments when using revoke_all.");
            next;
        }

        foreach my $user (@users) {
            my $u = LJ::load_user($user);
            unless ($u) {
                $self->error("Invalid username: $user");
                next;
            }

            my $shmsg;
            my $rv;
            if ($action eq "grant") {
                if (LJ::check_priv($u, $priv, $arg)) {
                    $self->error("$user already has $priv:$arg");
                    next;
                }
                $rv = $u->grant_priv($priv, $arg);
                $shmsg = "Granting: '$priv' with arg '$arg'";
            } elsif ($action eq "revoke") {
                unless (LJ::check_priv($u, $priv, $arg)) {
                    $self->error("$user does not have $priv:$arg");
                    next;
                }
                $rv = $u->revoke_priv($priv, $arg);
                $shmsg = "Denying: '$priv' with arg '$arg'";
            } else {
                unless (LJ::check_priv($u, $priv)) {
                    $self->error("$user does not have any $priv privs");
                    next;
                }
                $rv = $u->revoke_priv_all($priv);
                $shmsg = "Denying: '$priv' with all args";
            }

            return $self->error("Unable to $action $priv:$arg")
                unless $rv;

            my $shtype = ($action eq "grant") ? "privadd" : "privdel";
            LJ::statushistory_add($u, $remote, $shtype, $shmsg);

            $self->info($shmsg . " for user '" . $u->user . "'.");
        }
    }

    return 1;
}

1;
