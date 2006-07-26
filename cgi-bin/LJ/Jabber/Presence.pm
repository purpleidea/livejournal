package LJ::Jabber::Presence;

use strict;
use warnings;
no warnings 'redefine';

use Carp qw(croak);

use LJ::MemCache;
use Digest::MD5 qw(md5_base64);

*_hash = \&md5_base64;

=head1 PACKAGE METHODS

=head2 $obj = LJ::Jabber::Presence->new( $u, $resource )

Loads a Jabber presence object from Memcache, or failing that from the database.

Requires two arguments, a LJ::User object (or something that's similar) and a resource
(string) for the Jabber user instance

=cut

sub new {
    my $class = shift;
    my ($u, $resource) = @_;

    $u = LJ::want_user($u);

    croak "No user" unless $u;
    croak "No resource" unless $resource;

    my $self = {
        u        => $u,
        resource => $resource,
    };

    bless $self, $class;

    my $userid = $u->id;
    my $reshash = $self->reshash;

    my $memcached = LJ::MemCache::get( [$userid, "jabpresence:$userid:$reshash"] );

    if ($memcached) {
        %$self = (%$self, %$memcached);
        return $self;
    }

    my $dbh = LJ::get_db_reader() or die "No db";

    my $row = $dbh->selectrow_hashref("SELECT clusterid, client, presence, flags FROM jabpresence ".
                                      "WHERE userid=? AND reshash=? AND resource=?",
                                      undef, $self->u->id, $self->reshash, $self->resource);

    die $dbh->errstr if $dbh->errstr;

    %$self = (%$self, %$row);

    return $self;
}

=head2 $obj = LJ::Jabber::Presence->create( %opts );

Creates a Jabber::Presence object from %opts and saves it to the database.

Options are as follows:

=over

=item u

LJ::User object (or similar) representing the user this presence applies to

=item resource

String of Jabber resource for this user's particular presence.

=item cluster

LJ::Jabber::Cluster object representing the cluster node which this user has connected to.

=item presence

Raw XML string of presence data for this user's presence.

=item flags

Integer freeform flags field for storing anything you want. Please document it.

=item client

String field for holding users client type/version information... for debugging? (Artur will have to explain this)

=back

=cut

sub create {
    my $class = shift;
    my %opts = @_;

    my $raw_u    = delete( $opts{u} )        or croak "No user";
    my $resource = delete( $opts{resource} ) or croak "No resource";
    my $cluster  = delete( $opts{cluster} )  or croak "No cluster";
    my $client   = delete( $opts{client} );
    my $presence = delete( $opts{presence} ) or croak "No presence";
    my $flags    = delete( $opts{flags} ) || 0;

    croak( "Unknown options: " . join( ',', keys %opts ) )
        if (keys %opts);

    my $u = LJ::want_user( $raw_u );
    my $clusterid = _cluster_id( $cluster );

    my $self = bless {
                      u         => $u,
                      resource  => $resource,
                      cluster   => $cluster,
                      clusterid => $clusterid,
                      client    => $client,
                      presence  => $presence,
                      flags     => $flags,
                     }, $class;

    my $dbh = LJ::get_db_writer() or die "No db";

    my $sth = $dbh->prepare( "INSERT INTO jabpresence (userid, reshash, resource, clusterid, presence, flags) ".
                             "VALUES (?, ?, ?, ?, ?, ?)" );
    $sth->execute( $u->id, $self->reshash, $resource, $clusterid, $presence, $flags );

    if ($dbh->errstr) {
        warn "Insertion error: $dbh->{errstr}";
        return;
    }

    $self->_update_memcache_index();

    return $self;
}

=head1 HYBRID METHODS

=head2 $obj->get_resources()

=head2 $obj->get_resources( $userid )

=head2 LJ::Jabber::Presence->get_resources( $userid )

This method is for fetching a hashref with keys for each resource a userid is logged in with. The $userid arg is implied to be that of the current object, which will fail if you use this as a package method without an argument.

=cut

sub get_resources {
    my $self = shift;

    my $userid;
    if (@_) {
        $userid = shift;
    }
    else {
        $userid = $self->u->id;
    }

    my $resources = LJ::MemCache::get( [$userid, "jabuser:$userid"] );

    return $resources if $resources;

    return $self->_update_memcache_index($userid);
}

=head2 $obj->delete()

=head2 $obj->delete( $userid, $resource )

=head2 LJ::Jabber::Presence->delete( $userid, $resource )

This method is for deleting a single presence instance of a particular userid. The $userid and $resource arguments are implied to be those of the current object if omitted (which may not even be an object, but in that case it will fail)

=cut

sub delete {
    my $self = shift;

    my ($userid, $resource, $reshash);
    if (@_) {
        $userid = shift;
        $resource = shift;
        $reshash = _hash($resource);
    }
    else {
        $userid = $self->u->id;
        $resource = $self->resource;
        $reshash = $self->reshash;
    }

    croak "Invalid userid" unless $userid;
    croak "Invalid resource" unless $resource;

    my $dbh = LJ::get_db_writer() or die "No db";

    my $sth = $dbh->do( "DELETE FROM jabpresence WHERE userid=? AND reshash=? AND resource=?",
                        undef, $userid, $reshash, $resource );

    if ($dbh->errstr) {
        warn "Delete error: $dbh->{errstr}";
        return;
    }

    LJ::MemCache::delete( "jabpresence:$userid:$reshash" );
    $self->_update_memcache_index( $userid );

    return;
}

=head2 $obj->delete_all()

=head2 $obj->delete_all( $userid )

=head2 LJ::Jabber::Presence->delete_all( $userid )

This method is for deleting all instances of a particular userid. The $userid argument is implied to be that of the current object if omitted (which may not even be an object, but in that case it will fail)

=cut

sub delete_all {
    my $self = shift;

    my $userid;
    if (@_) {
        $userid = shift;
    }
    else {
        $userid = $self->u->id;
    }

    croak "Invalid userid" unless $userid;

    my $resources = LJ::Jabber::Presence->get_resources( $userid );

    my $dbh = LJ::get_db_writer() or die "No db";

    my $sth = $dbh->do( "DELETE FROM jabpresence WHERE userid=?",
                        undef, $userid );

    if ($dbh->errstr) {
        warn "Delete error: $dbh->{errstr}";
        return;
    }

    foreach my $resource (keys %$resources) {
        my $reshash = _hash( $resource );
        LJ::MemCache::delete( [$userid, "jabpresence:$userid:$reshash" ] );
    }

    $self->_update_memcache_index( $userid );

    return;
}

=head1 OBJECT METHODS

=head2 $obj->u

=head2 $obj->resource

=head2 $obj->reshash

=head2 $obj->cluster

=head2 $obj->clusterid

=head2 $obj->presence

=head2 $obj->client

General purpose accessors for attributes on these objects.

=cut

sub u        { $_[0]->{u} }
sub resource { $_[0]->{resource} }
sub presence { $_[0]->{presence} }
sub flags    { $_[0]->{flags} }
sub client   { $_[0]->{client} }

sub clusterid {
    my $self = shift;
    return ($self->{clusterid} ||= _cluster_id( $self->{cluster} ));
}

sub cluster  {
    my $self = shift;
    return ($self->{cluster} ||= _cluster_address( $self->{clusterid} ));
}

sub reshash  {
    my $self = shift;
    return ($self->{reshash} ||= _hash( $self->{resource} ));
}

=head2 $obj->set_presence( $val )

=head2 $obj->set_flags( $val )

=head2 $obj->set_client( $val )

Setters for values on these objects.

=cut

sub set_presence {
    my $self = shift;
    my $val = shift;

    croak( "Didn't pass in a defined value to set" )
        unless defined $val;

    $self->{presence} = $val;

    $self->_save( 'presence' );

    return $val;
}

sub set_flags {
    my $self = shift;
    my $val = shift;

    croak "Didn't pass in a defined value to set"
        unless defined $val;

    $self->_save( 'flags' );

    return $val;
}

sub set_client {
    my $self = shift;
    my $val = shift;

    croak "Didn't pass in a defined value to set"
        unless defined $val;

    $self->_save( 'client' );

    return $val;
}

# Internal functions

my %savable_cols = map { ($_, 1) } qw(presence flags);

sub _save {
    my $self = shift;

    return unless @_;

    my @bad_cols = grep {!$savable_cols{$_}} @_;
    die "Cannot save cols " . join( ',', @bad_cols ) . "."
        if @bad_cols;

    my $userid = $self->u->id;
    my $reshash = $self->reshash;

    my $dbh = LJ::get_db_writer() or die "No db";

    $dbh->do( "UPDATE jabpresence SET " . join( ', ', map { "$_ = ?" } @_ ) .
              " WHERE userid=? AND reshash=? AND resource=?", undef,
              (map { $self->{$_} } @_), $userid, $reshash, $self->resource );

    die "Database update failed: " . $dbh->errstr
        if $dbh->errstr;

    LJ::MemCache::delete( [$userid, "jabpresence:$userid:$reshash"], 0 );
}

my %cluster_address;

sub _cluster_address {
    my $id = shift;
    die "No id" unless $id;

    if (my $address = $cluster_address{$id}) {
        return $address;
    }

    my $address = LJ::MemCache::get( "jabclusterid:$id" );

    return $cluster_address{$id} = $address
        if $address;

    my $dbh = LJ::get_db_reader() or die "No db";

    $address = $dbh->selectrow_array( "SELECT address FROM jabcluster WHERE clusterid=?", undef, $id )
        or return;

    LJ::MemCache::set( "jabclusterid:$id", $address );

    return $address;
}

my %cluster_id;

sub _cluster_id {
    my $address = shift;
    die "No address" unless $address;

    if (my $id = $cluster_id{$address}) {
        return $id;
    }

    my $id = LJ::MemCache::get( "jabclusteraddr:$address" );

    return $cluster_id{$address} = $id
        if $id;

    # Loop over this action a few times so INSERT/SELECT races don't cause us to bail
    my $tries = 0;
    my $dbr = LJ::get_db_reader() or die "No db";
    my $dbh;

    until ($id or $tries > 3)
    {
        if ($tries++ > 2) {
            die "Insert failed, and address was not found in DB";
        }

        $id = $dbr->selectrow_array( "SELECT clusterid FROM jabcluster WHERE address=?",
                                     undef, $address );
        last if $id;

        $dbh ||= LJ::get_db_writer() or die "No db";

        $dbh->do( "INSERT INTO jabcluster (address) VALUES (?)", undef, $address )
            or next;

        $id = $dbh->{mysql_insertid};
    }

    LJ::MemCache::set( "jabclusteraddr:$address", $id );
    return $id;
}

sub _update_memcache_index {
    my $self = shift;
    my $userid = scalar( @_ ) ? shift : $self->u->id;

    my $dbh = LJ::get_db_writer() or die "No db";

    my $key = "jabuser:$userid";
    my $memcache_key = [$userid, $key];

    # Delete before we lock so failures past here can be detected in other threads.
    LJ::MemCache::delete( $memcache_key );

    { # Get a mysql lock before we read the DB and update memcache.
        my $lockstatus = $dbh->selectrow_array( qq{SELECT GET_LOCK("$key",5)} );
        unless ($lockstatus) {
            if (defined $lockstatus) {
                die "Lock attempt timed out on uid '$userid'";
            }
            else {
                die "Lock attempt failure, possible errstr'" . $dbh->errstr . "'";
            }
        }
    }

    # Use the DB writer for reading because we locked on it, and we lose our lock if the mysql thread dies.
    my $resources = $dbh->selectall_hashref( "SELECT resource, reshash FROM jabpresence WHERE userid=?",
                                             "resource", undef, $userid );

    die "DB SELECT failed: '$dbh->{errstr}'" if $dbh->errstr;
    die "DB returned undef" unless defined $resources;

    LJ::MemCache::set( $memcache_key, $resources );

    $dbh->do( qq{SELECT RELEASE_LOCK("$key")} );
    warn "Releasing lock failed badly: $dbh->{errstr}" if $dbh->errstr;

    return $resources;
}

1;
