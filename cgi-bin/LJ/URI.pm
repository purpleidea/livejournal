# This is a module for handling URIs
use strict;

package LJ::URI;

use LJ::Pay::Wallet;

# Takes an Apache a path to BML filename relative to htdocs
sub bml_handler {
    my ($class, $filename) = @_;

    LJ::Request->handler("perl-script");
    LJ::Request->notes("bml_filename" => "$LJ::HOME/htdocs/$filename");
    LJ::Request->push_handlers(PerlHandler => \&Apache::BML::handler);
    return LJ::Request::OK;
}

sub api_handler {
    my ($class) = @_;
    Apache::LiveJournal::Interface::Api->load;
    LJ::Request->handler("perl-script");
    LJ::Request->push_handlers(PerlHandler => \&Apache::LiveJournal::Interface::Api::handler);
    return LJ::Request::OK;
}

# Handle a URI. Returns response if success, undef if not handled
# Takes URI and Apache $r
sub handle {
    my ($class, $uri) = @_;

    return undef unless $uri;

    # handle "RPC" URIs
    if (my ($rpc) = $uri =~ m!^.*/__rpc_(\w+)$!) {
        my $bml_handler_path = $LJ::AJAX_URI_MAP{$rpc};

        return LJ::URI->bml_handler($bml_handler_path) if $bml_handler_path;
    }

    # handle "API" endpoint
    if ($uri =~ /^\/__api_endpoint.*$/) {
        return LJ::URI->api_handler();        
    }

    ## URI "/pics" can be handle only under user domains
    return undef if $uri =~ /^\/pics/;

    # handle normal URI mappings
    if (my $bml_file = $LJ::URI_MAP{$uri}) {
        return LJ::URI->bml_handler($bml_file);
    }

    # handle URI redirects
    if (my $url = $LJ::URI_REDIRECT{$uri}) {
        return Apache::LiveJournal::redir($url, LJ::Request::HTTP_MOVED_TEMPORARILY);
    }

    my $args = LJ::Request->args;
    my $full_uri = $uri;
    $full_uri .= "?$args" if $args;

    ########
    #
    # Now we handle verticals as subproject of community directory via LJ::Browse
    #
    ########

    # handle vertical URLs
    if (my $v = LJ::Vertical->load_by_url($full_uri)) {
        return LJ::URI->bml_handler("browse/index.bml");
    }

    if (my $c = LJ::Browse->load_by_url($full_uri)) {
        return LJ::URI->bml_handler("browse/index.bml");
    }

    if ($uri =~ m!^/statistics(/.*|$)! or $uri =~ m!^/ratings(/.*|$)! and not $uri eq '/ratings/admin.bml') {
        return LJ::URI->bml_handler("statistics/index.bml");
    }

    if ( $uri =~ m!^/singles(/.*|$)! ) {
        return LJ::URI->bml_handler("singles/index.bml");
    }

    return undef;
}

1;
