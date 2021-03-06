# AtomAPI support for LJ

package Apache::LiveJournal::Interface::AtomAPI;

use strict;
use Digest::SHA1;
use MIME::Base64;
use lib "$ENV{LJHOME}/cgi-bin";

require 'parsefeed.pl';
require 'fbupload.pl';

use LJ::TimeUtil;

# for Class::Autouse (so callers can 'ping' this method to lazy-load this class)
sub load { 1 }

# check allowed Atom upload filetypes
sub check_mime {
    my $mime = shift;
    return unless $mime;

    # TODO: add audio/etc support
    my %allowed_mime = (
        image => qr{^image\/(?:gif|jpe?g|png|tiff?)$}i,
        #audio => qr{^(?:application|audio)\/(?:(?:x-)?ogg|wav)$}i
    );

    foreach (keys %allowed_mime) {
        return $_ if $mime =~ $allowed_mime{$_}
    }
    return;
}

sub respond {
    my ($status, $body, $type) = @_;

    my %msgs = (
        200 => 'OK',
        201 => 'Created',

        400 => 'Bad Request',
        401 => 'Authentication Failed',
        403 => 'Forbidden',
        404 => 'Not Found',
        500 => 'Server Error',
    ),

    my %mime = (
        html => 'text/html',
        atom => 'application/x.atom+xml',
        xml  => "text/xml; charset='utf-8'",
    );

    # if the passed in body was a reference, send it
    # without any modification.  otherwise, send some
    # prettier html to the client.
    my $out;
    if (ref $body) {
        $out = $$body;
    } else {
        $out = <<HTML;
<html><head><title>$status $msgs{$status}</title></head><body>
<h1>$msgs{$status}</h1><hr /><p>$body</p>
</body></html>
HTML
    }

    $type = $mime{$type} || 'text/html';
    LJ::Request->status_line("$status $msgs{$status}");
    LJ::Request->content_type($type);
    LJ::Request->send_http_header();
    LJ::Request->print($out);
    return LJ::Request::OK;
};

sub handle_upload
{
    my ($remote, $u, $opts, $entry) = @_;

    # entry could already be populated from a standalone
    # service.post posting.
    my $standalone = $entry ? 1 : 0;
    unless ($entry) {
        my $buff;

        # Check length
        my $len = LJ::Request->header_in("Content-length");
        return respond(400, "Content is too long")
            if $len > $LJ::MAX_ATOM_UPLOAD;

        LJ::Request->read($buff, $len);

        eval { $entry = XML::Atom::Entry->new( \$buff ); };
        return respond(400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
            if $@;
    }

    my $mime = $entry->content()->type();
    my $mime_area = check_mime( $mime );
    return respond(400, "Unsupported MIME type: $mime") unless $mime_area;

    if ($mime_area eq 'image') {

        return respond(400, "Unable to upload media. Your account doesn't have the required access.")
            unless LJ::get_cap($u, 'fb_can_upload') && $LJ::FB_SITEROOT;

        my $err;
        LJ::load_user_props(
            $u,
            qw/ emailpost_gallery emailpost_imgsecurity /
        );

        my $summary = LJ::trim( $entry->summary() );

        my $fb = LJ::FBUpload::do_upload(
            $u, \$err,
            {
                path    => $entry->title(),
                rawdata => \$entry->content()->body(),
                imgsec  => $u->{emailpost_imgsecurity},
                caption => $summary,
                galname => $u->{emailpost_gallery} || 'Mobile',
            }
        );

        return respond(500, "There was an error uploading the media: $err")
            if $err || ! $fb;

        if (ref $fb && $fb->{Error}->{code}) {
            my $errstr = $fb->{Error}->{content};
            return respond(500, "There was an error uploading the media: $errstr");
        }

        my $atom_reply = XML::Atom::Entry->new();
        $atom_reply->title( $fb->{Title} );

        if ($standalone) {
            $atom_reply->summary('Media post');
            my $id = "atom:$u->{user}:$fb->{PicID}";
            $fb->{Summary} = $summary;

            $u->set_cache("lifeblog_fb:$fb->{PicID}", $fb);

            $atom_reply->id( "urn:fb:$LJ::FB_DOMAIN:$id" );
        }

        my $link = XML::Atom::Link->new();
        $link->type('text/html');
        $link->rel('alternate');
        $link->href( $fb->{URL} );
        $atom_reply->add_link($link);

        LJ::Request->header_out("Location", $fb->{URL});
        return respond(201, \$atom_reply->as_xml(), 'atom');
    }
}

sub handle_post {
    my ($remote, $u, $opts) = @_;
    my ($buff, $entry);

    # Check length
    my $len = LJ::Request->header_in("Content-length");
    return respond(400, "Content is too long")
        if $len > $LJ::MAX_ATOM_UPLOAD;

    # read the content
    LJ::Request->read($buff, $len);

    # try parsing it
    eval { $entry = XML::Atom::Entry->new( \$buff ); };
    return respond(400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
        if $@;

    # on post, the entry must NOT include an id
    return respond(400, "Must not include an <b>&lt;id&gt;</b> field in a new entry.")
        if $entry->id;

    # detect 'standalone' media posts
    return handle_upload( @_, $entry )
        if $entry->get("http://sixapart.com/atom/typepad#", 'standalone');

    # remove the SvUTF8 flag. See same code in synsuck.pl for
    # an explanation
    $entry->title(   LJ::no_utf8_flag( $entry->title         ));
    $entry->link(    LJ::no_utf8_flag( $entry->link          ));
    $entry->content( LJ::no_utf8_flag( $entry->content->body ));

    my @tags;

    eval {
        my @subjects = $entry->getlist('http://purl.org/dc/elements/1.1/', 'subject');
        push @tags, @subjects;
    };
    warn "Subjects parsing from ATOM died: $@" if $@;

    eval {
        my @categories = $entry->categories;
        push @tags, map { $_->label || $_->term } @categories;
    };
    warn "Categories parsing from ATOM died: $@" if $@;

    my $security_opts = { security => 'public' };

    # TODO Add code for handling this with XML::Atom::ext
    if ($XML::Atom::Version <= .13) {
        eval {
            foreach my $allow_element (map { XML::Atom::Util::nodelist($_, 'http://www.sixapart.com/ns/atom/privacy', 'allow') }
                                             XML::Atom::Util::nodelist($entry->{doc}, 'http://www.sixapart.com/ns/atom/privacy', 'privacy')) {

                my $policy = $allow_element->getAttribute('policy');
                next unless $policy eq 'http://www.sixapart.com/ns/atom/permissions#read';

                my $ref = $allow_element->getAttribute('ref');

                if ($ref =~ m/#(everyone|friends|self)$/) {
                    $security_opts = {
                        everyone => {
                            security => 'public',
                        },
                        friends  => {
                            security => 'usemask',
                            allowmask => 1,
                        },
                        self     => {
                            security => 'private',
                        },
                    }->{$1};
                }
            }
        };

        if ($@) {
            warn "While parsing privacy handling on AtomAPI call: $@\n";
        }
    }

    # Retrieve fotobilder media links from clients that embed via
    # standalone tags or service.upload transfers.  Add to post entry
    # body.
    my $body  = $entry->content()->body();
    my @links = $entry->link();
    my (@images, $link_count);
    foreach my $link (@links) {
        # $link is now a valid XML::Atom::Link object
        my $rel  = $link->get('rel');
        my $type = $link->get('type');
        my $id   = $link->get('href');

        next unless $rel eq 'related' && check_mime($type) &&
            $id =~ /^urn:fb:\Q$LJ::FB_DOMAIN\E:atom:\w+:(\d+)$/;

        my $fb_picid = $1;

        my $fb = $u->cache("lifeblog_fb:$fb_picid");
        next unless $fb;

        push @images, {
            url     => $fb->{URL},
            width   => $fb->{Width},
            height  => $fb->{Height},
            caption => $fb->{Summary},
            title   => $fb->{Title}
        };
    }

    $body .= LJ::FBUpload::make_html( $u, \@images );

    my $preformatted = $entry->get
        ("http://sixapart.com/atom/post#", "convertLineBreaks") eq 'false' ? 1 : 0;

    # build a post event request.
    my $req = {
        'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
        'ver'         => 1,
        'username'    => $u->{'user'},
        'lineendings' => 'unix',
        'subject'     => $entry->title(),
        'event'       => $body,
        'props'       => { opt_preformatted => $preformatted, taglist => \@tags },
        'tz'          => 'guess',
        %$security_opts,
    };
    $req->{'props'}->{'interface'} = "atom";

    my $err;
    my $res = LJ::Protocol::do_request("postevent",
                                       $req, \$err, { 'noauth' => 1 });

    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond(500, "Unable to post new entry. Protocol error: <b>$errstr</b>.");
    }

    my $atom_reply = XML::Atom::Entry->new();
    $atom_reply->title( $entry->title );

    my $content_body = $entry->content->body;
    $atom_reply->summary( substr( $content_body, 0, 100 ) );
    $atom_reply->content( $content_body );

    my $lj_entry = LJ::Entry->new($u, jitemid => $res->{itemid});
    $atom_reply->id( $lj_entry->atom_id );

    my $link;
    my $edit_url = "$LJ::SITEROOT/interface/atom/edit/$res->{'itemid'}";

    my $add_category = sub {
        my $category = XML::Atom::Category->new;
        $category->term(shift);
        $atom_reply->add_category($category);
    };

    # Old versions of XML::Atom don't have a category object, do it manually
    if ($XML::Atom::VERSION <= .21) {
        $add_category = sub {
            my $term = shift;
            $atom_reply->category(undef, { term => $term });
        };
    }

    foreach my $tag (@tags) {
        local $@;
        eval { $add_category->($tag) };
        warn "Unable to add category to XML::Atom feed: $@"
            if $@;
    }

    $link = XML::Atom::Link->new();
    $link->type('application/x.atom+xml');
    $link->rel('service.edit');
    $link->href( $edit_url );
    $link->title( $entry->title() );
    $atom_reply->add_link($link);

    $link = XML::Atom::Link->new();
    $link->type('text/html');
    $link->rel('alternate');
    $link->href( $res->{url} );
    $link->title( $entry->title() );
    $atom_reply->add_link($link);

    LJ::Request->header_out("Location", $edit_url);
    return respond(201, \$atom_reply->as_xml(), 'atom');
}

sub handle_edit {
    my ($remote, $u, $opts) = @_;

    my $method = $opts->{'method'};

    # first, try to load the item and fail if it's not there
    my $jitemid = $opts->{'param'};
    my $req = {
        'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
            $u->{'user'} : undef,
         'ver' => 1,
         'username' => $u->{'user'},
         'selecttype' => 'one',
         'itemid' => $jitemid,
    };

    my $err;
    my $olditem = LJ::Protocol::do_request("getevents",
                                           $req, \$err, { 'noauth' => 1 });

    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond(404, "Unable to retrieve the item requested for editing. Protocol error: <b>$errstr</b>.");
    }
    $olditem = $olditem->{'events'}->[0];

    if ($method eq "GET") {
        # return an AtomEntry for this item
        # use the interface between make_feed and create_view_atom in
        # ljfeed.pl

        # get the log2 row (need logtime for createtime)
        my $row = LJ::get_log2_row($u, $jitemid) ||
            return respond(404, "Could not load the original entry.");

        # we need to put into $item: itemid, ditemid, subject, event,
        # createtime, eventtime, modtime

        my $ctime = LJ::TimeUtil->mysqldate_to_time($row->{'logtime'}, 1);

        my $tagstring = $olditem->{'props'}->{'taglist'} || '';
        my $tags = [ split(/\s*,\s*/, $tagstring) ];

        my $item = {
            'itemid'     => $olditem->{'itemid'},
            'ditemid'    => $olditem->{'itemid'}*256 + $olditem->{'anum'},
            'eventtime'  => LJ::TimeUtil->alldatepart_s2($row->{'eventtime'}),
            'createtime' => $ctime,
            'modtime'    => $olditem->{'props'}->{'revtime'} || $ctime,
            'subject'    => $olditem->{'subject'},
            'event'      => $olditem->{'event'},
            'tags'       => $tags,
        };

        my $ret = LJ::Feed::create_view_atom(
            { 'u' => $u },
            $u,
            {
                'single_entry' => 1,
                'apilinks'     => 1,
            },
            [$item]
        );

        return respond(200, \$ret, 'xml');
    }

    if ($method eq "PUT") {
        # Check length
        my $len = LJ::Request->header_in("Content-length");
        return respond(400, "Content is too long")
            if $len > $LJ::MAX_ATOM_UPLOAD;

        # read the content
        my $buff;
        LJ::Request->read($buff, $len);

        # try parsing it
        my $entry;
        eval { $entry = XML::Atom::Entry->new( \$buff ); };
        return respond(400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
            if $@;

        # remove the SvUTF8 flag. See same code in synsuck.pl for
        # an explanation
        $entry->title(   LJ::no_utf8_flag( $entry->title         ));
        $entry->link(    LJ::no_utf8_flag( $entry->link          ));
        $entry->content( LJ::no_utf8_flag( $entry->content->body ));

        # the AtomEntry must include <id> which must match the one we sent
        # on GET
        unless ($entry->id() =~ m#atom1:$u->{'user'}:(\d+)$# &&
                $1 == $olditem->{'itemid'}*256 + $olditem->{'anum'}) {
            return respond(400, "Incorrect <b>&lt;id&gt;</b> field in this request.");
        }

        # build an edit event request. Preserve fields that aren't being
        # changed by this item (perhaps the AtomEntry isn't carrying the
        # complete information).

        $req = {
            'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
            'ver'         => 1,
            'username'    => $u->{'user'},
            'itemid'      => $jitemid,
            'lineendings' => 'unix',
            'subject'     => $entry->title() || $olditem->{'subject'},
            'event'       => $entry->content()->body() || $olditem->{'event'},
            'props'       => $olditem->{'props'},
            'security'    => $olditem->{'security'},
            'allowmask'   => $olditem->{'allowmask'},
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent",
                                           $req, \$err, { 'noauth' => 1 });

        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond(500, "Unable to update entry. Protocol error: <b>$errstr</b>.");
        }

        return respond(200, "The entry was successfully updated.");
    }

    if ($method eq "DELETE") {

        # build an edit event request to delete the entry.

        $req = {
            'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
                $u->{'user'}:undef,
            'ver' => 1,
            'username' => $u->{'user'},
            'itemid' => $jitemid,
            'lineendings' => 'unix',
            'event' => '',
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent",
                                           $req, \$err, { 'noauth' => 1 });

        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond(500, "Unable to delete entry. Protocol error: <b>$errstr</b>.");
        }

        return respond(200, "Entry successfully deleted.");
    }

}

# fetch lj tags, display as categories
sub handle_categories
{
    my ($remote, $u, $opts) = @_;
    my $ret = '<?xml version="1.0"?>';
    $ret .= '<categories xmlns="http://sixapart.com/atom/category#">';

    my $tags = LJ::Tags::get_usertags($u, { remote => $remote }) || {};
    foreach (sort { $a->{name} cmp $b->{name} } values %$tags) {
        $ret .= "<subject xmlns=\"http://purl.org/dc/elements/1.1/\">$_->{name}</subject>";
    }
    $ret .= '</categories>';

    return respond(200, \$ret, 'xml');
}

sub handle_feed {
    my ($remote, $u, $opts) = @_;

    # simulate a call to the S1 data view creator, with appropriate
    # options

    my %op = ('pathextra' => "/atom",
              'apilinks'  => 1,
              );
    my $ret = LJ::Feed::make_feed($u, $remote, \%op);

    unless (defined $ret) {
        if ($op{'redir'}) {
            # this happens if the account was renamed or a syn account.
            # the redir URL is wrong because ljfeed.pl is too
            # dataview-specific. Since this is an admin interface, we can
            # just fail.
            return respond(404, "The account <b>$u->{'user'} </b> is of a wrong type and does not allow AtomAPI administration.");
        }
        if ($op{'handler_return'}) {
            # this could be a conditional GET shortcut, honor it
            LJ::Request->status($op{'handler_return'});
            return LJ::Request::OK;
        }
        # should never get here
        return respond(404, "Unknown error.");
    }

    # everything's fine, return the XML body with the correct content type
    return respond(200, \$ret, 'xml');

}

# this routine accepts the apache request handle, performs
# authentication, calls the appropriate method handler, and
# prints the response.
sub handle {

    { #
        my $r = shift;
        LJ::Request->init($r) unless LJ::Request->is_inited;
    }

    my $have_xmlatom = eval {
        require XML::Atom;
        require XML::Atom::Feed;
        require XML::Atom::Entry;
        require XML::Atom::Link;
        XML::Atom->VERSION < 0.09 ? 0 : 1
    };

    return respond(404, "This server does not support the Atom API.")
        unless $have_xmlatom;

    # break the uri down: /interface/atom/<verb>[/<number>]
    # or old format:      /interface/atomapi/<username>/<verb>[/<number>]
    my $uri = LJ::Request->uri;

    # convert old format to new format:
    my $username;   # old
    if ($uri =~ s!^/interface/atomapi/(\w+)/!/interface/atom/!) {
        $username = $1;
    }

    $uri =~ s!^/interface/atom/?!! or return respond(404, "Bogus URL");
    my ($action, $param) = split(m!/!, $uri);

    my $valid_actions = qr{feed|edit|post|upload|categories};

    my $u = LJ::Auth::Method::Digest::auth_digest();
    return respond(401, "Authentication failed for this AtomAPI request.")
        unless $u;

    # service autodiscovery
    # TODO: Add communities?
    my $method = LJ::Request->method;
    if ( $method eq 'GET' && ! $action ) {
        LJ::load_user_props( $u, 'journaltitle' );
        my $title = $u->{journaltitle} || $u->{user};
        my $feed = XML::Atom::Feed->new();

        my $add_link = sub {
            my $subservice = shift;
            my $link = XML::Atom::Link->new();
            $link->title($title);
            $link->type('application/x.atom+xml');
            $link->rel("service.$subservice");
            $link->href("$LJ::SITEROOT/interface/atom/$subservice");
            $feed->add_link($link);
        };

        foreach my $subservice (qw/ post edit feed categories /) {
            $add_link->($subservice);
        }

        $add_link->('upload') if LJ::get_cap($u, 'fb_can_upload') && $LJ::FB_SITEROOT;

        my $link = XML::Atom::Link->new();
        $link->title($title);
        $link->type('text/html');
        $link->rel('alternate');
        $link->href( LJ::journal_base($u) );
        $feed->add_link($link);

        return respond(200, \$feed->as_xml(), 'atom');
    }

    $action =~ /^$valid_actions$/
      or return respond(400, "Unknown URI scheme: /interface/atom/<b>" . LJ::ehtml($action) . "</b>");

    unless (($action eq 'feed' and $method eq 'GET')  or
            ($action eq 'categories' and $method eq 'GET') or
            ($action eq 'post' and $method eq 'POST') or
            ($action eq 'upload' and $method eq 'POST') or
            ($action eq 'edit' and
             {'GET'=>1,'PUT'=>1,'DELETE'=>1}->{$method})) {
        return respond(400, "URI scheme /interface/atom/<b>" . LJ::ehtml($action) . "</b> is incompatible with request method <b>$method</b>.");
    }

    if (($action ne 'edit' && $param) or
        ($action eq 'edit' && $param !~ m#^\d+$#)) {
        return respond(400, "Either the URI lacks a required parameter, or its format is improper.");
    }

    # we've authenticated successfully and remote is set. But can remote
    # manage the requested account?
    my $remote = LJ::get_remote();
    unless ($remote && $remote->can_manage($u)) {
        return respond(403, "User <b>$remote->{'user'}</b> has no administrative access to account <b>$u->{user}</b>.");
    }

    # handle the requested action
    my $opts = {
        'action' => $action,
        'method' => $method,
        'param'  => $param
    };

    {
        'feed'       => \&handle_feed,
        'post'       => \&handle_post,
        'edit'       => \&handle_edit,
        'upload'     => \&handle_upload,
        'categories' => \&handle_categories,
    }->{$action}->($remote, $u, $opts);

    return LJ::Request::OK;
}

1;
