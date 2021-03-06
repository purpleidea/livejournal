#!/usr/bin/perl
#

package LJ;
use strict;

use lib "$ENV{LJHOME}/cgi-bin";

# load the bread crumb hash
require "crumbs.pl";

use Carp;
use LJ::Auth::Challenge;
use LJ::Request;
use LJ::JSON;
use Class::Autouse qw(
                      LJ::Event
                      LJ::Subscription::Pending
                      LJ::M::ProfilePage
                      LJ::Directory::Search
                      LJ::Directory::Constraint
                      LJ::M::FriendsOf
                      );
use LJ::ControlStrip;
use LJ::SiteScheme;
use LJ::Pics::Album;
use LJ::URI::Shortener;
use Apache::WURFL;
use Encode;
use Digest::SHA qw/sha1_base64/;

# <LJFUNC>
# name: LJ::img
# des: Returns an HTML &lt;img&gt; or &lt;input&gt; tag to an named image
#      code, which each site may define with a different image file with
#      its own dimensions.  This prevents hard-coding filenames & sizes
#      into the source.  The real image data is stored in LJ::Img, which
#      has default values provided in cgi-bin/imageconf.pl but can be
#      overridden in etc/ljconfig.pl.
# args: imagecode, type?, attrs?
# des-imagecode: The unique string key to reference the image.  Not a filename,
#                but the purpose or location of the image.
# des-type: By default, the tag returned is an &lt;img&gt; tag, but if 'type'
#           is "input", then an input tag is returned.
# des-attrs: Optional hashref of other attributes.  If this isn't a hashref,
#            then it's assumed to be a scalar for the 'name' attribute for
#            input controls.
# </LJFUNC>
sub img
{
    my $ic = shift;
    my $type = shift;  # either "" or "input"
    my $attr = shift;

    my $attrs;
    my $alt;
    if ($attr) {
        if (ref $attr eq "HASH") {
            $alt = LJ::ehtml($attr->{alt}) if (exists $attr->{alt});
            foreach (keys %$attr) {
                $attrs .= " $_=\"" . LJ::ehtml($attr->{$_}) . "\""
                    unless ((lc $_) eq 'alt');
            }
        } else {
            $attrs = " name=\"$attr\"";
        }
    }

    my $i = $LJ::Img::img{$ic};
    $alt ||= LJ::Lang::string_exists($i->{'alt'}) ? LJ::Lang::ml($i->{'alt'}) : $i->{'alt'};
    if ($type eq "") {
        return "<img src=\"$LJ::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" ".
            "height=\"$i->{'height'}\" alt=\"$alt\" title=\"$alt\" ".
            "border='0'$attrs />";
    }
    if ($type eq "input") {
        return "<input type=\"image\" src=\"$LJ::IMGPREFIX$i->{'src'}\" ".
            "width=\"$i->{'width'}\" height=\"$i->{'height'}\" title=\"$alt\" ".
            "alt=\"$alt\" border='0'$attrs />";
    }
    return "<b>XXX</b>";
}

# <LJFUNC>
# name: LJ::date_to_view_links
# class: component
# des: Returns HTML of date with links to user's journal.
# args: u, date
# des-date: date in yyyy-mm-dd form.
# returns: HTML with yyyy, mm, and dd all links to respective views.
# </LJFUNC>
sub date_to_view_links
{
    my ($u, $date) = @_;
    return unless $date =~ /^(\d\d\d\d)-(\d\d)-(\d\d)/;

    my ($y, $m, $d) = ($1, $2, $3);
    my ($nm, $nd) = ($m+0, $d+0);   # numeric, without leading zeros
    my $user = $u->{'user'};
    my $base = LJ::journal_base($u);

    my $ret;
    $ret .= "<a href=\"$base/$y/\">$y</a>-";
    $ret .= "<a href=\"$base/$y/$m/\">$m</a>-";
    $ret .= "<a href=\"$base/$y/$m/$d/\">$d</a>";
    return $ret;
}


# <LJFUNC>
# name: LJ::auto_linkify
# des: Takes a plain-text string and changes URLs into <a href> tags (auto-linkification).
# args: str
# des-str: The string to perform auto-linkification on.
# returns: The auto-linkified text.
# </LJFUNC>
sub auto_linkify
{
    my $str = shift;
    my $match = sub {
        my $str = shift;
        if ($str =~ /^(.*?)(&(#39|quot|lt|gt)(;.*)?)$/) {
            return "<a href='$1'>$1</a>$2";
        } else {
            return "<a href='$str'>$str</a>";
        }
    };
    $str =~ s!(https?://[^\s\'\"\<\>]+[a-zA-Z0-9_/&=\-])! $match->($1); !ge;
    return $str;
}

# return 1 if URL is a safe stylesheet that S1/S2/etc can pull in.
# return 0 to reject the link tag
# return a URL to rewrite the stylesheet URL
# $href will always be present.  $host and $path may not.
sub valid_stylesheet_url {
    my ($href, $host, $path) = @_;
    unless ($host && $path) {
        return 0 unless $href =~ m!^https?://([^/]+?)(/.*)$!;
        ($host, $path) = ($1, $2);
    }

    my $cleanit = sub {
        # allow tag, if we're doing no css cleaning
        return 1 if $LJ::DISABLED{'css_cleaner'};

        # remove tag, if we have no CSSPROXY configured
        return 0 unless $LJ::CSSPROXY;

        # rewrite tag for CSS cleaning
        return "$LJ::CSSPROXY?u=" . LJ::eurl($href);
    };

    return 1 if $LJ::TRUSTED_CSS_HOST{$host};
    return $cleanit->() unless $host =~ /\Q$LJ::DOMAIN\E$/i;

    # let users use system stylesheets.
    return 1 if $host eq $LJ::DOMAIN || $host eq $LJ::DOMAIN_WEB ||
        $href =~ /^\Q$LJ::STATPREFIX\E/;

    # S2 stylesheets:
    return 1 if $path =~ m!^(/\w+)?/res/(\d+)/stylesheet(\?\d+)?$!;

    # unknown, reject.
    return $cleanit->();
}


# <LJFUNC>
# name: LJ::make_authas_select
# des: Given a u object and some options, determines which users the given user
#      can switch to.  If the list exists, returns a select list and a submit
#      button with labels.  Otherwise returns a hidden element.
# returns: string of HTML elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'authas' - current user, gets selected in drop-down;
#           'label' - label to go before form elements;
#           'button' - button label for submit button;
#           others - arguments to pass to [func[LJ::get_authas_list]];
#           check_paid - for each user in list will set parameter 'data-paid:0|1', used by JS
# </LJFUNC>
sub make_authas_select {
    my ($u, $opts) = @_; # type, authas, label, button

    die "make_authas_select called outside of web context"
        unless LJ::is_web_context();

    my @list = LJ::get_authas_list($u, $opts);

    # only do most of form if there are options to select from
    shift @list if @list && $opts->{'remove_self'};
    if (@list > 1 || $opts->{'show_me'} || $list[0] ne $u->{'user'}) {
        my $ret;
        my $label = $BML::ML{'web.authas.label'};
        $label = $BML::ML{'web.authas.label.comm'} if ($opts->{'type'} eq "C");
        $ret = ($opts->{'label'} || $label) . " ";
        my %select_id = $opts->{'id'} ? ( id => $opts->{'id'} ) : ();
        $ret .= LJ::html_select({ 'name' => 'authas',
                                 'selected' => $opts->{'authas'} || $u->{'user'},
                                 'class' => 'hideable',
                                 %select_id,
                                 },
                                 ## We loaded all users in LJ::get_authas_list(). Here we use their singletons.
                                 (map {
                                    my $u = LJ::load_user ($_);
                                    my %is_paid = $opts->{'check_paid'}
                                        ? ($u && ($u->get_cap('perm') || $u->get_cap('paid'))
                                            ? ( js_data => " data-paid='1' " )
                                            : ( js_data => " data-paid='0' " )
                                          )
                                        : undef;
                                    {
                                        text    => $_,
                                        value   => $u->display_name,
                                        %is_paid,
                                    }
                                } @list), @{$opts->{'add_fields'}} ) . " ";
        $ret .= $opts->{'button_tag'} . LJ::html_submit(undef, $opts->{'button'} || $BML::ML{'web.authas.btn'}) . $opts->{'button_close_tag'};
        return $ret;
    }

    # no communities to choose from, give the caller a hidden
    my $ret = LJ::html_hidden('authas', $opts->{'authas'} || $u->{'user'});
    $ret .= $opts->{'nocomms'} if $opts->{'nocomms'};
    return $ret;
}

# <LJFUNC>
# name: LJ::make_postto_select
# des: Given a u object and some options, determines which users the given user
#      can post to.  If the list exists, returns a select list and a submit
#      button with labels.  Otherwise returns a hidden element.
# returns: string of HTML elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'postto' - current user, gets selected in drop-down;
#           'label' - label to go before form elements;
#           'button' - button label for submit button;
#           others - arguments to pass to [func[LJ::get_postto_list]].
# </LJFUNC>
sub make_postto_select {
    my ($u, $opts) = @_; # type, authas, label, button

    my @list = LJ::get_postto_list($u, $opts);

    # only do most of form if there are options to select from
    if (@list > 1) {
        return ($opts->{'label'} || $BML::ML{'web.postto.label'}) . " " .
               LJ::html_select({ 'name' => 'authas',
                                 'selected' => $opts->{'authas'} || $u->{'user'}},
                                 map { $_, $_ } @list) . " " .
               LJ::html_submit(undef, $opts->{'button'} || $BML::ML{'web.postto.btn'});
    }

    # no communities to choose from, give the caller a hidden
    return  LJ::html_hidden('authas', $opts->{'authas'} || $u->{'user'});
}

# <LJFUNC>
# name: LJ::help_icon
# des: Returns BML to show a help link/icon given a help topic, or nothing
#      if the site hasn't defined a URL for that topic.  Optional arguments
#      include HTML/BML to place before and after the link/icon, should it
#      be returned.
# args: topic, pre?, post?
# des-topic: Help topic key.
#            See doc/ljconfig.pl.txt, or [special[helpurls]] for examples.
# des-pre: HTML/BML to place before the help icon.
# des-post: HTML/BML to place after the help icon.
# </LJFUNC>
sub help_icon
{
    my $topic = shift;
    my $pre = shift;
    my $post = shift;
    return "" unless (defined $LJ::HELPURL{$topic});
    return "$pre<?help $LJ::HELPURL{$topic} help?>$post";
}

# like help_icon, but no BML.
sub help_icon_html {
    my $topic = shift;
    my $url = $LJ::HELPURL{$topic} or return "";
    my $pre = shift || "";
    my $post = shift || "";
    my $title = shift || "";
    my $helplink_class = ($title) ? "b-helplink b-helplink-withtitle" : "b-helplink";
    my $title_wrapper = ($title) ? "<span class=\"b-helplink-title\">$title</span>" : "";
    # FIXME: use LJ::img() here, not hard-coding width/height
    return "$pre<a href=\"$url\" class=\"$helplink_class\" target=\"_blank\" title=\"Help\"><span class=\"b-helplink-icon\"></span>$title_wrapper</a>$post";
}

# <LJFUNC>
# name: LJ::bad_input
# des: Returns common BML for reporting form validation errors in
#      a bulleted list.
# returns: BML showing errors.
# args: error*
# des-error: A list of errors
# </LJFUNC>
sub bad_input
{
    my @errors = @_;
    my $ret = "";
    $ret .= "<?badcontent?>\n<ul>\n";
    foreach my $ei (@errors) {
        my $err  = LJ::errobj($ei) or next;
        $err->log;
        $ret .= $err->as_bullets;
    }
    $ret .= "</ul>\n";
    return $ret;
}


# <LJFUNC>
# name: LJ::error_list
# des: Returns an error bar with bulleted list of errors.
# returns: BML showing errors.
# args: error*
# des-error: A list of errors
# </LJFUNC>
sub error_list
{
    # FIXME: retrofit like bad_input above?  merge?  make aliases for each other?
    my @errors = @_;
    my $ret;
    $ret .= '<div class="errorbar">';
    $ret .= "<strong>";
    $ret .= BML::ml('error.procrequest');
    $ret .= "</strong><ul>";

    foreach my $ei (@errors) {
        my $err  = LJ::errobj($ei) or next;
        $err->log;
        $ret .= $err->as_bullets;
    }
    $ret .= " </ul></div>";
    return $ret;
}


# <LJFUNC>
# name: LJ::error_noremote
# des: Returns an error telling the user to log in.
# returns: Translation string "error.notloggedin"
# </LJFUNC>
sub error_noremote
{
    return "<?needlogin?>";
}


# <LJFUNC>
# name: LJ::warning_list
# des: Returns a warning bar with bulleted list of warnings.
# returns: BML showing warnings
# args: warnings*
# des-warnings: A list of warnings
# </LJFUNC>
sub warning_list
{
    my @warnings = @_;
    my $ret;

    $ret .= "<?warningbar ";
    $ret .= "<strong>";
    $ret .= BML::ml('label.warning');
    $ret .= "</strong><ul>";

    foreach (@warnings) {
        $ret .= "<li>$_</li>";
    }
    $ret .= " </ul> warningbar?>";
    return $ret;
}

sub tosagree_widget {
    my ($checked, $errstr) = @_;

    return
        "<div class='formitemDesc'>" .
        BML::ml('tos.mustread',
                { aopts => "target='_new' href='$LJ::SITEROOT/legal/tos.bml'" }) .
        "</div>" .
        "<iframe width='684' height='300' src='/legal/tos-mini.bml' " .
        "style='border: 1px solid gray;'></iframe>" .
        "<div>" . LJ::html_check({ name => 'agree_tos', id => 'agree_tos',
                                   value => '1', selected =>  $checked }) .
        "<label for='agree_tos'>" . BML::ml('tos.haveread') . "</label></div>" .
        ($errstr ? "<?inerr $errstr inerr?>" : '');
}

sub tosagree_html {
    my $domain = shift;

    my $ret = "<?h1 $LJ::REQUIRED_TOS{title} h1?>";

    my $html_str = LJ::tosagree_str($domain => 'html');
    $ret .= "<?p $html_str p?>" if $html_str;

    $ret .= "<div style='margin-left: 40px; margin-bottom: 20px;'>";
    $ret .= LJ::tosagree_widget(@_);
    $ret .= "</div>";

    return $ret;
}

sub tosagree_str {
    my ($domain, $key) = @_;

    return ref $LJ::REQUIRED_TOS{$domain} && $LJ::REQUIRED_TOS{$domain}->{$key} ?
        $LJ::REQUIRED_TOS{$domain}->{$key} : $LJ::REQUIRED_TOS{$key};
}

# <LJFUNC>
# name: LJ::did_post
# des: Cookies should only show pages which make no action.
#      When an action is being made, check the request coming
#      from the remote user is a POST request.
# info: When web pages are using cookie authentication, you can't just trust that
#       the remote user wants to do the action they're requesting.  It's way too
#       easy for people to force other people into making GET requests to
#       a server.  What if a user requested http://server/delete_all_journal.bml,
#       and that URL checked the remote user and immediately deleted the whole
#       journal?  Now anybody has to do is embed that address in an image
#       tag and a lot of people's journals will be deleted without them knowing.
#       Cookies should only show pages which make no action.  When an action is
#       being made, check that it's a POST request.
# returns: true if REQUEST_METHOD == "POST"
# </LJFUNC>
sub did_post
{
    return (BML::get_method() eq "POST");
}

# <LJFUNC>
# name: LJ::robot_meta_tags
# des: Returns meta tags to instruct a robot/crawler to not index or follow links.
# returns: A string with appropriate meta tags
# </LJFUNC>
sub robot_meta_tags
{
    return "<meta name=\"robots\" content=\"noindex, nofollow, noarchive\" />\n" .
           "<meta name=\"googlebot\" content=\"noindex, nofollow, noarchive, nosnippet\" />\n";
}

sub paging_bar
{
    my ($page, $pages, $opts) = @_;

    my $self_link = $opts->{'self_link'} ||
                    sub { BML::self_link({ 'page' => $_[0] }) };

    my $href_opts = $opts->{'href_opts'} || sub { '' };

    my $navcrap;
    if ($pages > 1) {
        $navcrap .= "<center><font face='Arial,Helvetica' size='-1'><b>";
        $navcrap .= BML::ml('ljlib.pageofpages',{'page'=>$page, 'total'=>$pages}) . "<br />";
        my $left = "<b>&lt;&lt;</b>";
        if ($page > 1) { $left = "<a href='" . $self_link->($page-1) . "'" . $href_opts->($page-1) . ">$left</a>"; }
        my $right = "<b>&gt;&gt;</b>";
        if ($page < $pages) { $right = "<a href='" . $self_link->($page+1) . "'" . $href_opts->($page+1) . ">$right</a>"; }
        $navcrap .= $left . " ";
        for (my $i=1; $i<=$pages; $i++) {
            my $link = "[$i]";
            if ($i != $page) { $link = "<a href='" . $self_link->($i) . "'" .  $href_opts->($i) . ">$link</a>"; }
            else { $link = "<font size='+1'><b>$link</b></font>"; }
            $navcrap .= "$link ";
        }
        $navcrap .= "$right";
        $navcrap .= "</font></center>\n";
        $navcrap = BML::fill_template("standout", { 'DATA' => $navcrap });
    }
    return $navcrap;
}

# <LJFUNC>
# class: web
# name: LJ::make_cookie
# des: Prepares cookie header lines.
# returns: An array of cookie lines.
# args: name, value, expires, path?, domain?
# des-name: The name of the cookie.
# des-value: The value to set the cookie to.
# des-expires: The time (in seconds) when the cookie is supposed to expire.
#              Set this to 0 to expire when the browser closes. Set it to
#              undef to delete the cookie.
# des-path: The directory path to bind the cookie to.
# des-domain: The domain (or domains) to bind the cookie to.
# </LJFUNC>
sub make_cookie
{
    my ($name, $value, $expires, $path, $domain) = @_;
    my $cookie = "";
    my @cookies = ();

    # let the domain argument be an array ref, so callers can set
    # cookies in both .foo.com and foo.com, for some broken old browsers.
    if ($domain && ref $domain eq "ARRAY") {
        foreach (@$domain) {
            push(@cookies, LJ::make_cookie($name, $value, $expires, $path, $_));
        }
        return;
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($expires);
    $year+=1900;

    my @day = qw{Sunday Monday Tuesday Wednesday Thursday Friday Saturday};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};

    $cookie = sprintf "%s=%s", LJ::eurl($name), LJ::eurl($value);

    # this logic is confusing potentially
    unless (defined $expires && $expires==0) {
        $cookie .= sprintf "; expires=$day[$wday], %02d-$month[$mon]-%04d %02d:%02d:%02d GMT",
                $mday, $year, $hour, $min, $sec;
    }

    $cookie .= "; path=$path" if $path;
    $cookie .= "; domain=$domain" if $domain;
    push(@cookies, $cookie);
    return @cookies;
}

sub set_active_crumb
{
    $LJ::ACTIVE_CRUMB = shift;
    return undef;
}

sub set_dynamic_crumb
{
    my ($title, $parent) = @_;
    $LJ::ACTIVE_CRUMB = [ $title, $parent ];
}

sub get_parent_crumb
{
    my $thiscrumb = LJ::get_crumb(LJ::get_active_crumb());
    return LJ::get_crumb($thiscrumb->[2]);
}

sub get_active_crumb
{
    return $LJ::ACTIVE_CRUMB;
}

sub get_crumb_path
{
    my $cur = LJ::get_active_crumb();
    my @list;
    while ($cur) {
        # get crumb, fix it up, and then put it on the list
        if (ref $cur) {
            # dynamic crumb
            push @list, [ $cur->[0], '', $cur->[1], 'dynamic' ];
            $cur = $cur->[1];
        } else {
            # just a regular crumb
            my $crumb = LJ::get_crumb($cur);
            last unless $crumb;
            last if $cur eq $crumb->[2];
            $crumb->[3] = $cur;
            push @list, $crumb;

            # now get the next one we're going after
            $cur = $crumb->[2]; # parent of this crumb
        }
    }
    return @list;
}

sub get_crumb
{
    my $crumbkey = shift;
    if (defined $LJ::CRUMBS_LOCAL{$crumbkey}) {
        return $LJ::CRUMBS_LOCAL{$crumbkey};
    } else {
        return $LJ::CRUMBS{$crumbkey};
    }
}

# <LJFUNC>
# name: LJ::check_referer
# class: web
# des: Checks if the user is coming from a given URI.
# args: uri?, referer?
# des-uri: string; the URI we want the user to come from.
# des-referer: string; the location the user is posting from.
#              If not supplied, will be retrieved with BML::get_client_header.
#              In general, you don't want to pass this yourself unless
#              you already have it or know we can't get it from BML.
# returns: 1 if they're coming from that URI, else undef
# </LJFUNC>
sub check_referer {
    my $uri = shift(@_) || '';
    my $referer = shift(@_) || BML::get_client_header('Referer');

    # get referer and check
    return 1 unless $referer;
    return 1 if $LJ::SITEROOT   && $referer =~ m!^$LJ::SITEROOT$uri!;
    return 1 if $LJ::DOMAIN     && $referer =~ m!^http://$LJ::DOMAIN$uri!;
    return 1 if $LJ::DOMAIN_WEB && $referer =~ m!^http://$LJ::DOMAIN_WEB$uri!;
    return 1 if $LJ::USER_VHOSTS && $referer =~ m!^http://([A-Za-z0-9_\-]{1,15})\.$LJ::DOMAIN$uri!;
    return 1 if $uri =~ m!^http://! && $referer eq $uri;
    return undef;
}

# <LJFUNC>
# name: LJ::repost_auth
# class: web
# des: Creates an authentication token to be used later to verify that a form hidden field "repost"
#      not modified by user
# args: type, username, url
# des-type: type of repost, see LJSUP-8061
# des-username: name of original poster
# des-url: url of original post
# returns: HTML hidden field to be inserted into the output of a page.
# </LJFUNC>
sub repost_auth {
    my ($type, $username, $url, $subject, $raw) = @_;
    my $str  = join( ':', map ( LJ::eurl($_), $type, $username, $url, $subject));
    my $auth = Digest::MD5::md5_hex( $str . $LJ::REPOST_SECRET );

    return $auth if $raw;

    $str .= ":$auth";
    return LJ::html_hidden("repost_params", $str);
}

# <LJFUNC>
# name: LJ::form_auth
# class: web
# des: Creates an authentication token to be used later to verify that a form
#      submission came from a particular user.
# args: raw?
# des-raw: boolean; If true, returns only the token (no HTML).
# returns: HTML hidden field to be inserted into the output of a page.
# </LJFUNC>
sub form_auth {
    my $raw = shift;
    my $chal = $LJ::REQ_GLOBAL{form_auth_chal};

    unless ($chal) {
        my $remote = LJ::get_remote();
        my $id     = $remote ? $remote->id : 0;
        my $sess   = $remote && $remote->session ? $remote->session->id : LJ::UniqCookie->current_uniq;

        my $auth = join('-', LJ::rand_chars(10), $id, $sess);
        $chal = LJ::Auth::Challenge->generate(86400, $auth);
        $LJ::REQ_GLOBAL{form_auth_chal} = $chal;
    }

    return $raw ? $chal : LJ::html_hidden("lj_form_auth", $chal);
}

# <LJFUNC>
# name: LJ::check_form_auth
# class: web
# des: Verifies form authentication created with [func[LJ::form_auth]].
# returns: Boolean; true if the current data in %POST is a valid form, submitted
#          by the user in $remote using the current session,
#          or false if the user has changed, the challenge has expired,
#          or the user has changed session (logged out and in again, or something).
# </LJFUNC>
sub check_form_auth {
    my $opts = shift;
    my $formauth = $BMLCodeBlock::POST{'lj_form_auth'};
    if (ref $opts eq 'HASH') {
        $formauth = $opts->{'lj_form_auth'} if defined $opts->{'lj_form_auth'};
    } else {
        $formauth = $opts if defined $opts;
        $opts = {};
    }
    return 0 unless $formauth;

    my $remote = LJ::get_remote();
    my $id     = $remote ? $remote->id : 0;
    my $sess   = $remote && $remote->session ? $remote->session->id : LJ::UniqCookie->current_uniq;

    # check the attributes are as they should be
    my $attr = LJ::get_challenge_attributes($formauth);
    my ($randchars, $chal_id, $chal_sess) = split(/\-/, $attr);

    return 0 unless $id   == $chal_id;
    return 0 unless $sess eq $chal_sess;

    # check the signature is good and not expired
    return LJ::Auth::Challenge->check($formauth, {
        dont_check_count => !$opts->{'enable_check_count'},
    } );
}

# <LJFUNC>
# name: LJ::create_qr_div
# class: web
# des: Creates the hidden div that stores the QuickReply form.
# returns: undef upon failure or HTML for the div upon success
# args: user, remote, ditemid, stylemine, userpic
# des-u: user object or userid for journal reply in.
# des-ditemid: ditemid for this comment.
# des-stylemine: if the user has specified style=mine for this page.
# des-userpic: alternate default userpic.
# </LJFUNC>
sub create_qr_div {

    my ($user, $ditemid, $stylemine, $userpic, $viewing_thread, $text_hint) = @_;
    my $u = LJ::want_user($user);
    my $remote = LJ::get_remote();
    return undef unless $u && $remote && $ditemid;
    return undef if $remote->underage;

    $stylemine ||= 0;
    my $qrhtml;

    LJ::load_user_props($remote, "opt_no_quickreply");
    return undef if $remote->{'opt_no_quickreply'};

    $qrhtml .= "<div id='qrformdiv'><form id='qrform' name='qrform' method='POST' action='$LJ::SITEROOT/talkpost_do.bml'>";
    $qrhtml .= LJ::form_auth();

    my $stylemineuri = $stylemine ? "style=mine&" : "";
    my $basepath =  LJ::journal_base($u) . "/$ditemid.html?${stylemineuri}";
    my $usertype;

    if ($remote->is_identity && $remote->is_trusted_identity) {
        $usertype = lc($remote->identity->short_code) . '_cookie';
    } else {
        $usertype = 'cookieuser';
    }

    $qrhtml .= LJ::html_hidden({'name' => 'replyto', 'id' => 'replyto', 'value' => ''},
                               {'name' => 'parenttalkid', 'id' => 'parenttalkid', 'value' => ''},
                               {'name' => 'journal', 'id' => 'journal', 'value' => $u->{'user'}},
                               {'name' => 'itemid', 'id' => 'itemid', 'value' => $ditemid},
                               {'name' => 'usertype', 'id' => 'usertype', 'value' => $usertype },
                               {'name' => 'qr', 'id' => 'qr', 'value' => '1'},
                               {'name' => 'cookieuser', 'id' => 'cookieuser', 'value' => $remote->{'user'}},
                               {'name' => 'dtid', 'id' => 'dtid', 'value' => ''},
                               {'name' => 'basepath', 'id' => 'basepath', 'value' => $basepath},
                               {'name' => 'stylemine', 'id' => 'stylemine', 'value' => $stylemine},
                               {'name' => 'viewing_thread', 'id' => 'viewing_thread', 'value' => $viewing_thread},
                               );

    # rate limiting challenge
    {
        $qrhtml .= LJ::html_hidden("chrp1", LJ::Talk::generate_chrp1($u->{userid}, $ditemid));
    }

    # Start making the div itself
    $qrhtml .= "<table style='border: 1px solid black'>";
    $qrhtml .= "<tr valign='center'>";
    $qrhtml .= "<td align='right'><b>".BML::ml('/talkpost.bml.opt.from')."</b></td><td align='left'>";
    $qrhtml .= LJ::ljuser($remote->{'user'});
    $qrhtml .= "</td><td align='center'>";

    my (%userpicmap, $defaultpicurl);

    # Userpic selector
    {
        my %res;
        LJ::do_request({ "mode" => "login",
                         "ver" => ($LJ::UNICODE ? "1" : "0"),
                         "user" => $remote->{'user'},
                         "getpickws" => 1,
                         'getpickwurls' => 1, },
                       \%res, { "noauth" => 1, "userid" => $remote->{'userid'}}
                       );

        if ($res{'pickw_count'}) {
            $qrhtml .= BML::ml('/talkpost.bml.label.picturetouse2',
                               {
                                   'aopts'=>"href='$LJ::SITEROOT/allpics.bml?user=$remote->{'user'}'"});
            my @pics;
            for (my $i=1; $i<=$res{'pickw_count'}; $i++) {
                push @pics, $res{"pickw_$i"};
            }
            @pics = sort { lc($a) cmp lc($b) } @pics;
            $qrhtml .= LJ::html_select({'name' => 'prop_picture_keyword',
                                        'selected' => $userpic, 'id' => 'prop_picture_keyword', 'tabindex' => '8' },
                                       ("", BML::ml('/talkpost.bml.opt.defpic'), map { ($_, $_) } @pics));

            # userpic browse button
            $qrhtml .= qq {
                <input type="button" id="lj_userpicselect" value="Browse" onclick="QuickReply.userpicSelect()" tabindex="9" />
                } unless $LJ::DISABLED{userpicselect} || ! $remote->get_cap('userpicselect');

            $qrhtml .= LJ::help_icon_html("userpics", " ");

            foreach my $i (1 .. $res{'pickw_count'}) {
                $userpicmap{$res{"pickw_$i"}} = $res{"pickwurl_$i"};
            }

            if (my $upi = $remote->userpic) {
                $defaultpicurl = $upi->url;
            }
        }
    }

    $qrhtml .= "</td></tr>";

    $qrhtml .= "<tr><td align='right' valign='top'>";
    $qrhtml .= "<b>".BML::ml('/talkpost.bml.opt.subject')."</b></td>";
    $qrhtml .= "<td colspan='2' align='left'>";
    $qrhtml .= "<input class='textbox' type='text' size='50' maxlength='100' name='subject' id='subject' value='' tabindex='10' />";

    $qrhtml .= "<div id=\"subjectCaptionText\">" . $text_hint . "</div>" if $text_hint;

    $qrhtml .= "</td></tr>";

    $qrhtml .= "<tr valign='top'>";
    $qrhtml .= "<td align='right'><b>".BML::ml('/talkpost.bml.opt.message')."</b></td>";
    $qrhtml .= "<td colspan='3' style='width: 90%'>";

    $qrhtml .= "<textarea class='textbox' rows='10' cols='50' wrap='soft' name='body' id='body' style='width: 99%' tabindex='20'></textarea>";
    $qrhtml .= "</td></tr>";

    $qrhtml .= LJ::run_hook('extra_quickreply_rows', {
        'user'    => $user,
        'ditemid' => $ditemid,
    });

    $qrhtml .= "<tr><td>&nbsp;</td>";
    $qrhtml .= "<td colspan='3' align='left'>";

    $qrhtml .= LJ::html_submit('submitpost', BML::ml('/talkread.bml.button.post'),
                               { 'id' => 'submitpost',
                                 'raw' => q|onclick="if (QuickReply.check()){ QuickReply.submit() }" tabindex='30' |,
                                 });

    $qrhtml .= "&nbsp;" . LJ::html_submit('submitmoreopts', BML::ml('/talkread.bml.button.more'),
                                          { 'id' => 'submitmoreopts', 'tabindex' => '31',
                                            'raw' => 'onclick="if (QuickReply.more()){ QuickReply.submit() }"'
                                            });
    if ($LJ::SPELLER) {
        $qrhtml .= "&nbsp;<input type='checkbox' name='do_spellcheck' value='1' id='do_spellcheck' tabindex='32' /> <label for='do_spellcheck'>";
        $qrhtml .= BML::ml('/talkread.bml.qr.spellcheck');
        $qrhtml .= "</label>";
    }

    LJ::load_user_props($u, 'opt_logcommentips');
    if ($u->{'opt_logcommentips'} eq 'A') {
        $qrhtml .= '<p class="b-bubble b-bubble-alert b-bubble-noarrow b-bubble-intext b-qrform-alert-logcommentips">';
        $qrhtml .= LJ::deemp(BML::ml('/talkpost.bml.logyourip'));
        $qrhtml .= LJ::help_icon_html("iplogging", " ");
        $qrhtml .= "</p>";
    }

    $qrhtml .= "</td></tr></table>";
    $qrhtml .= "</form></div>";

    my $ret;
    $ret = "<script type=\"text/javascript\">\n";

    $qrhtml = LJ::ejs($qrhtml);

    # here we create some separate fields for saving the quickreply entry
    # because the browser will not save to a dynamically-created form.

    my $qrsaveform .= LJ::ejs(LJ::html_hidden(
                                      {'name' => 'saved_subject', 'id' => 'saved_subject'},
                                      {'name' => 'saved_body', 'id' => 'saved_body'},
                                      {'name' => 'saved_spell', 'id' => 'saved_spell'},
                                      {'name' => 'saved_upic', 'id' => 'saved_upic'},
                                      {'name' => 'saved_dtid', 'id' => 'saved_dtid'},
                                      {'name' => 'saved_ptid', 'id' => 'saved_ptid'},
                                      ));

    %userpicmap = map { (LJ::ehtml($_) => $userpicmap{$_}) } keys %userpicmap;

    my $userpicmap = LJ::JSON->to_json(\%userpicmap);
    $ret .= qq{
               var userpicmap = $userpicmap;
               var defaultpicurl = "$defaultpicurl";
               document.write("$qrsaveform");
               var de = document.createElement('div');
               de.id = 'qrdiv';
               de.innerHTML = "$qrhtml";
               de.style.display = 'none';
               document.body.insertBefore(de, document.body.firstChild);
           };

    $ret .= "</script>";

    return $ret;
}

# <LJFUNC>
# name: LJ::make_qr_link
# class: web
# des: Creates the link to toggle the QR reply form or if
#      JavaScript is not enabled, then forwards the user through
#      to replyurl.
# returns: undef upon failure or HTML for the link
# args: dtid, basesubject, linktext, replyurl
# des-dtid: dtalkid for this comment
# des-basesubject: parent comment's subject
# des-linktext: text for the user to click
# des-replyurl: URL to forward user to if their browser
#               does not support QR.
# </LJFUNC>
sub make_qr_link
{
    my ($dtid, $basesubject, $linktext, $replyurl) = @_;

    return undef unless defined $dtid && $linktext && $replyurl;

    my $remote = LJ::get_remote();
    LJ::load_user_props($remote, "opt_no_quickreply");
    unless ($remote->{'opt_no_quickreply'}) {
        my $pid = int($dtid / 256);

        $basesubject =~ s/^(Re:\s*)*//i;
        $basesubject = "Re: $basesubject" if $basesubject;
        $basesubject = LJ::ehtml(LJ::ejs($basesubject));
        my $onclick = "return QuickReply.reply('$dtid',$pid,'$basesubject')";

        my $ju;
        $ju = LJ::load_userid(LJ::Request->notes('journalid')) if LJ::Request->is_inited and LJ::Request->notes('journalid');

        $onclick = "" if $ju->{'opt_whocanreply'} eq 'friends' and $remote and not LJ::is_friend($ju, $remote);
        return "<a href=\"$replyurl\" onclick=\"$onclick\" rel='nofollow'>$linktext</a>";
    } else { # QR Disabled
        return "<a href=\"$replyurl\" rel='nofollow'>$linktext</a>";
    }
}

# <LJFUNC>
# name: LJ::get_lastcomment
# class: web
# des: Looks up the last talkid and journal the remote user posted in.
# returns: talkid, jid
# args:
# </LJFUNC>
sub get_lastcomment {
    my $remote = LJ::get_remote();
    return (undef, undef) unless $remote;

    # Figure out their last post
    my $memkey = [$remote->{'userid'}, "lastcomm:$remote->{'userid'}"];
    my $memval = LJ::MemCache::get($memkey);
    my ($jid, $talkid);
    ($jid, $talkid) = split(/:/, $memval) if $memval;

    return ($talkid, $jid);
}

# <LJFUNC>
# name: LJ::make_qr_target
# class: web
# des: Returns a div usable for QuickReply boxes.
# returns: HTML for the div
# args:
# </LJFUNC>
sub make_qr_target {
    my $name = shift;

    return "<div id='ljqrt$name' name='ljqrt$name'></div>";
}

# <LJFUNC>
# name: LJ::set_lastcomment
# class: web
# des: Sets the lastcomm memcached key for this user's last comment.
# returns: undef on failure
# args: u, remote, dtalkid, life?
# des-u: Journal they just posted in, either u or userid
# des-remote: Remote user
# des-dtalkid: Talkid for the comment they just posted
# des-life: How long, in seconds, the memcached key should live.
# </LJFUNC>
sub set_lastcomment
{
    my ($u, $remote, $dtalkid, $life) = @_;

    my $userid = LJ::want_userid($u);
    return undef unless $userid && $remote && $dtalkid;

    # By default, this key lasts for 10 seconds.
    $life ||= 10;

    # Set memcache key for highlighting the comment
    my $memkey = [$remote->{'userid'}, "lastcomm:$remote->{'userid'}"];
    LJ::MemCache::set($memkey, "$userid:$dtalkid", time()+$life);

    return;
}

sub deemp {
    "<span class='de'>$_[0]</span>";
}

# <LJFUNC>
# name: LJ::entry_form
# class: web
# des: Returns a properly formatted form for creating/editing entries.
# args: head, onload, opts
# des-head: string reference for the <head> section (JavaScript previews, etc).
# des-onload: string reference for JavaScript functions to be called on page load
# des-opts: hashref of keys/values:
#           mode: either "update" or "edit", depending on context;
#           datetime: date and time, formatted yyyy-mm-dd hh:mm;
#           remote: remote u object;
#           subject: entry subject;
#           event: entry text;
#           richtext: allow rich text formatting;
#           auth_as_remote: bool option to authenticate as remote user, pre-filling pic/friend groups/etc.
# return: form to include in BML pages.
# </LJFUNC>
sub entry_form {
    my $widget = LJ::Widget::EntryForm->new;

    $widget->set_data(@_);
    return $widget->render;
}

# entry form subject
sub entry_form_subject_widget {
    my $class = shift;

    if ($class) {
        $class = qq { class="$class" };
    }
    return qq { <input name="subject" $class/> };
}

# entry form hidden date field
sub entry_form_date_widget {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year+=1900;
    $mon=sprintf("%02d", $mon+1);
    $mday=sprintf("%02d", $mday);
    $min=sprintf("%02d", $min);
    return LJ::html_hidden({'name' => 'date_ymd_yyyy', 'value' => $year, 'id' => 'update_year'},
                           {'name' => 'date_ymd_dd', 'value'  => $mday, 'id' => 'update_day'},
                           {'name' => 'date_ymd_mm', 'value'  => $mon,  'id' => 'update_mon'},
                           {'name' => 'hour', 'value' => $hour, 'id' => 'update_hour'},
                           {'name' => 'min', 'value'  => $min,  'id' => 'update_min'});
}

# entry form event text box
sub entry_form_entry_widget {
    my $class = shift;

    if ($class) {
        $class = qq { class="$class" };
    }

    return qq { <textarea cols=50 rows=10 name="event" $class></textarea> };
}


# entry form "journals can post to" dropdown
# NOTE!!! returns undef if no other journals user can post to
sub entry_form_postto_widget {
    my $remote = shift;

    return undef unless LJ::isu($remote);

    my $ret;
    # log in to get journals can post to
    my $res;
    $res = LJ::Protocol::do_request("login", {
        "ver" => $LJ::PROTOCOL_VER,
        "username" => $remote->{'user'},
    }, undef, {
        "noauth" => 1,
        "u" => $remote,
    });

    return undef unless $res;

    my @journals = map { $_, $_ } @{$res->{'usejournals'}};

    return undef unless @journals;

    push @journals, $remote->{'user'};
    push @journals, $remote->{'user'};
    @journals = sort @journals;
    $ret .= LJ::html_select({ 'name' => 'usejournal', 'selected' => $remote->{'user'}}, @journals) . "\n";
    return $ret;
}

sub entry_form_security_widget {
    my $ret = '';

    my @secs = ("public", BML::ml('label.security.public'),
                "private", BML::ml('label.security.private'),
                "friends", BML::ml('label.security.friends'));

    $ret .= LJ::html_select({ 'name' => 'security'},
                            @secs);

    return $ret;
}

sub entry_form_tags_widget {
    my $ret = '';

    return '' if $LJ::DISABLED{tags};

    $ret .= LJ::html_text({
                              'name'      => 'prop_taglist',
                              'size'      => '35',
                              'maxlength' => '255',
                          });
    $ret .= LJ::help_icon('addtags');

    return $ret;
}

# <LJFUNC>
# name: LJ::entry_form_decode
# class: web
# des: Decodes an entry_form into a protocol-compatible hash.
# info: Generate form with [func[LJ::entry_form]].
# args: req, post
# des-req: protocol request hash to build.
# des-post: entry_form POST contents.
 # returns: req
# </LJFUNC>
sub entry_form_decode
{
    my ($req, $POST) = @_;

    # find security
    my $sec = "public";
    my $amask = 0;
    if ($POST->{'security'} eq "private") {
        $sec = "private";
    } elsif ($POST->{'security'} eq "friends") {
        $sec = "usemask"; $amask = 1;
    } elsif ($POST->{'security'} eq "custom") {
        $sec = "usemask";
        foreach my $bit (0..30) {
            next unless $POST->{"custom_bit_$bit"};
            $amask |= (1 << $bit);
        }
    }
    $req->{'security'} = $sec;
    $req->{'allowmask'} = $amask;

    # date/time
    my $date = LJ::html_datetime_decode({ 'name' => "date_ymd", }, $POST);
    my ($year, $mon, $day) = split( /\D/, $date);

    my $time_value= $POST->{'time'}; # get value of hh::mm
    my ($hour, $min) = split ( /:/, $time_value);

    # TEMP: ease golive by using older way of determining differences
    my $date_old = LJ::html_datetime_decode({ 'name' => "date_ymd_old", }, $POST);
    my ($year_old, $mon_old, $day_old) = split( /\D/, $date_old);
    my ($hour_old, $min_old) = ($POST->{'hour_old'}, $POST->{'min_old'});

    my $different = $POST->{'min_old'} && (($year ne $year_old) || ($mon ne $mon_old)
                    || ($day ne $day_old) || ($hour ne $hour_old) || ($min ne $min_old));

    # this value is set when the JS runs, which means that the user-provided
    # time is sync'd with their computer clock. otherwise, the JS didn't run,
    # so let's guess at their timezone.
    if ($POST->{'date_diff'} || $POST->{'date_diff_nojs'} || $different) {
        $req->{'year'} = $year;
        $req->{'mon'} = $mon;
        $req->{'day'} = $day;
        $req->{'hour'} = $hour;
        $req->{'min'} = $min;
    }

    # copy some things from %POST
    foreach (qw(subject
                prop_picture_keyword prop_current_moodid
                prop_current_mood
                prop_opt_screening prop_opt_noemail
                prop_opt_preformatted prop_opt_nocomments prop_opt_lockcomments
                prop_current_location prop_current_coords
                prop_taglist prop_qotdid prop_give_features
                prop_ljart_event_town prop_ljart_event_location
                prop_ljart_event_paid prop_ljart_event_price
                prop_ljart_event_type prop_ljart_event_image
                prop_ljart_event_desc prop_ljart_event prop_ljart_event_users
                prop_ljart_portfolio_thumbnail prop_ljart_portfolio
                repost_budget paid_repost_on repost_limit_sc
                repost_targeting_age repost_targeting_gender
                repost_targeting_country repost_targeting_state
            )) {
        $req->{$_} = $POST->{$_};
    }

    # optional opts
    foreach (qw( prop_discovery )) {
        $req->{$_} = $POST->{$_} if defined $POST->{$_};
    } 

    if ( length( $POST->{'prop_current_music'} ) > 197 ) {
        my $pos = index( $POST->{'prop_current_music'}, '|' );

        if ( $pos == -1 ) {
            $req->{'prop_current_music'} = substr( $POST->{'prop_current_music'}, 0, 197 ) . '...';
        }
        else {
            $req->{'prop_current_music'} = substr( substr($POST->{'prop_current_music'}, 0, $pos), 0, 197 ) . '... ' . substr( $POST->{'prop_current_music'}, $pos );
        }
    }
    else {
        $req->{'prop_current_music'} = $POST->{'prop_current_music'};
    }

    if ($POST->{"subject"} eq BML::ml('entryform.subject.hint2')) {
        $req->{"subject"} = "";
    }

    $req->{"prop_opt_preformatted"} ||= $POST->{'switched_rte_on'} ? 1 :
        $POST->{'event_format'} eq "preformatted" ? 1 : 0;
    $req->{"prop_opt_nocomments"}   ||= $POST->{'comment_settings'} eq "nocomments" ? 1 : 0;
    $req->{'prop_opt_lockcomments'} ||= $POST->{'comment_settings'} eq 'lockcomments' ? 1 : 0;
    $req->{"prop_opt_noemail"}      ||= $POST->{'comment_settings'} eq "noemail" ? 1 : 0;
    $req->{'prop_opt_backdated'}      = $POST->{'prop_opt_backdated'} ? 1 : 0;
    $req->{'prop_opt_norating'}       = $POST->{'prop_opt_norating'} ? 1 : 0;

    my $ljart_date_from = $POST->{'prop_ljart_event_date_from'};
    my $ljart_date_to   = $POST->{'prop_ljart_event_date_to'};
    my $ljart_time_from = $POST->{'prop_ljart_event_time_from'};
    my $ljart_time_to   = $POST->{'prop_ljart_event_time_to'};

    $req->{'prop_ljart_event_date'} = $ljart_date_to ? "$ljart_date_from-$ljart_date_to" : $ljart_date_from;
    $req->{'prop_ljart_event_time'} = $ljart_time_to ? "$ljart_time_from-$ljart_time_to" : $ljart_time_from;

    $req->{'prop_copyright'} = $POST->{'prop_copyright'} ? 'P' : 'C' if LJ::is_enabled('default_copyright', LJ::get_remote())
                                    && $POST->{'defined_copyright'};
    $req->{'prop_poster_ip'} = LJ::get_remote_ip();

    my $uniq = LJ::UniqCookie->current_uniq();
    $req->{'prop_uniq'} = $uniq;

    if ( my $reposted_from = $POST->{'reposted_from'} ) {
        my $reposted_entry = LJ::Entry->new_from_url($reposted_from);

        #TODO: check visibility? it's not a security concern, but still
        if ($reposted_entry) {
            $req->{'prop_reposted_from'} = $reposted_entry->url;
        }
    }

    if (LJ::is_enabled("content_flag")) {
        $req->{prop_adult_content} = $POST->{prop_adult_content};
        $req->{prop_adult_content} = ""
            unless $req->{prop_adult_content} eq "none" || $req->{prop_adult_content} eq "concepts" || $req->{prop_adult_content} eq "explicit";
    }

    # nuke taglists that are just blank
    $req->{'prop_taglist'} = "" unless defined $req->{'prop_taglist'} && $req->{'prop_taglist'} =~ /\S/;

    # Convert the rich text editor output back to parsable lj tags.
    my $event = $POST->{'event'};
    if ($POST->{'switched_rte_on'}) {
        $req->{"prop_used_rte"} = 1;

        # We want to see if we can hit the fast path for cleaning
        # if they did nothing but add line breaks.
        my $attempt = $event;
        $attempt =~ s!<br />!\n!g;

        if ($attempt !~ /<\w/) {
            $event = $attempt;

            # Make sure they actually typed something, and not just hit
            # enter a lot
            $attempt =~ s!(?:<p>(?:&nbsp;|\s)+</p>|&nbsp;)\s*?!!gm;
            $event = '' unless $attempt =~ /\S/;

            $req->{'prop_opt_preformatted'} = 0;
        } else {
            # Old methods, left in for compatibility during code push
            $event =~ s!<lj-cut class="ljcut">!<lj-cut>!gi;

            $event =~ s!<lj-raw class="ljraw">!<lj-raw>!gi;
        }
    } else {
        $req->{"prop_used_rte"} = 0;
    }

    $req->{'event'} = $event;

    ## see if an "other" mood they typed in has an equivalent moodid
    if ($POST->{'prop_current_mood'}) {
        if (my $id = LJ::mood_id($POST->{'prop_current_mood'})) {
            $req->{'prop_current_moodid'} = $id;
        } else {
            $req->{'prop_current_moodid'} = '';
        }
    }

    # process site-specific options
    LJ::run_hooks('decode_entry_form', $POST, $req);

    return $req;
}

# returns exactly what was passed to it normally.  but in developer mode,
# it includes a link to a page that automatically grants the needed priv.
sub no_access_error {
    my ($text, $priv, $privarg) = @_;
    if ($LJ::IS_DEV_SERVER) {
        my $remote = LJ::get_remote();
        return "$text <b>(DEVMODE: <a href='/admin/priv/?devmode=1&user=$remote->{user}&priv=$priv&arg=$privarg'>Grant $priv\[$privarg\]</a>)</b>";
    } else {
        return $text;
    }
}

# Data::Dumper for JavaScript
sub js_dumper {
    my $obj = shift;
    if (ref $obj) {
        return LJ::JSON->to_json($obj);
    } else {
        return ($obj =~ /^[1-9]\d*$/) ?  $obj : '"' . LJ::ejs($obj) . '"';
    }
}

{
    my %stat_cache = ();  # key -> {lastcheck, modtime}
    sub _file_modtime {
        my ($key, $now) = @_;
        if (my $ci = $stat_cache{$key}) {
            if ($ci->{lastcheck} > $now - 10) {
                return $ci->{modtime};
            }
        }

        my $file = "$LJ::HOME/htdocs/$key";
        my $mtime = (stat($file))[9];
        $stat_cache{$key} = { lastcheck => $now, modtime => $mtime };
        return $mtime;
    }
}

## stc/0 is the empty file.
## its modtime is checked for all concatenated sources and it is updated
## for every release, so in the most cases this modtime
## as timestamp is used for "?v" param value.
sub stc_0_modtime {
    my $now = shift;
    $now = time() unless defined $now;

    ## touch-ing it changes ?v= param for all included res.
    return _file_modtime("stc/0", $now);
}

sub stat_src_to_url {
    my $url = shift;
    my $mtime = _file_modtime("/stc" . $url, time);
    return $LJ::STATPREFIX . $url . "?v=" . $mtime;
}

sub need_res_group {
    my (@groupnames) = @_;
    foreach my $name (@groupnames){
        my $group = $LJ::RES_GROUP_DEPS{$name};
        next unless $group;
        next if $LJ::REQ_GLOBAL{__need_res_group}->{$group}++;

        ## js, css, templates
        foreach my $resource_class (qw/js css templates/){
            next unless exists $group->{$resource_class};
            foreach my $files ($group->{$resource_class}){
                foreach my $resource (@$files){
                    if (ref $resource eq 'ARRAY'){
                        ## need_res expects $cond as a first argument,
                        ## but for config files other order is preferable:
                        ##    source file name at first place then condition at second
                        ##
                        ## support both
                        my ($file, $cond) = ref($resource->[0])
                                                ? ($resource->[1], $resource->[0])
                                                : ($resource->[0], $resource->[1]);
                        LJ::need_res($cond, $file);
                    } else {
                        LJ::need_res($resource);
                    }
                }
            }
        }

        ## ml
        if (my $mls = $group->{ml}){
            LJ::need_string(@$mls);
        }

        ## groups
        if (my $groups = $group->{groups}){
            LJ::need_res_group($_) for @$groups;
        }
    }
}

sub need_journal_res {
    LJ::need_string(qw{
        paidrepost.button.title
        paidrepost.button.title.owner
        paidrepost.button.title.curr
        paidrepost.button.title.delete
        paidrepost.button.title.counter

        paidrepost.button.label
        paidrepost.button.label.done

        entry.reference.label.title
        entry.reference.label.reposted
    });

    LJ::need_string(@LJ::REPOST_ML);

    LJ::need_res(@LJ::JOURNAL_RES_ALL);
}

## Support for conditional file inclusion:
## e.g. LJ::need_res( {condition => 'IE'}, 'ie.css', 'myie.css') will result in
## <!--[if IE]><link rel="stylesheet" type="text/css" href="$statprefix/..." /><![endif]-->
## Support 'args' option. Example: LJ::need_res( { args => 'media="screen"' }, 'stc/ljtimes/iframe.css' );
## Results in: <link rel="stylesheet" type="text/css" href="http://stat.lj-3-32.bulyon.local/ljtimes/iframe.css?v=1285833891" media="screen"/>
## LJ::need_res( {clean_list => 1} ) will suppress ALL previous resources and do NOTHING more!
## LJ::need_res( {insert_head => 1}, 'my.css' ) insert my.css to the head of the list of sources.
sub need_res {
    my $opts = (ref $_[0]) ? shift : {};
    my @keys = @_;

    if ($opts->{clean_list}) {
        %LJ::NEEDED_RES = ();
        %LJ::NAMED_NEED_RES = ();
        @LJ::NEEDED_RES = ();
        @LJ::INCLUDE_TEMPLATE = ();
        return;
    }

    my $insert_head = $opts->{insert_head} ? 1 : 0;

    my @reskeys = ();
    foreach my $key (@keys) {
        my $reskey  = $key;
        my $resopts = $opts;
        if (ref $reskey eq 'ARRAY'){
            $reskey  = $key->[1];
            $resopts = $key->[0];
        }

        if ( $reskey =~ m!^templates/! ) {
            push @LJ::INCLUDE_TEMPLATE, $reskey;
            next;
        }

        die "Bogus reskey $reskey" unless $reskey =~ m!^(js|stc)/!;

        if ($opts->{'separate_list'}) {
            unless (exists $LJ::NEEDED_RES_SEPARATE{$reskey}) {
                push @reskeys, $reskey;
            }
            $LJ::NEEDED_RES_SEPARATE{$reskey} = $resopts;
        } else {
            unless (exists $LJ::NEEDED_RES{$reskey}) {
                push @reskeys, $reskey;
            }
            $LJ::NEEDED_RES{$reskey} = $resopts;
        }
    }

    if ($opts->{'separate_list'}) {
        if ($insert_head) {
            unshift @LJ::NEEDED_RES_SEPARATE, @reskeys;
        } else {
            push @LJ::NEEDED_RES_SEPARATE, @reskeys;
        }
    } else {
        if ($insert_head) {
            unshift @LJ::NEEDED_RES, @reskeys;
        } else {
            push @LJ::NEEDED_RES, @reskeys;
        }
    }

    return;
}

sub include_raw  {
    my $type = shift;
    my $code = shift;

    die "Bogus include type: $type"
        unless $type =~ m!^(?:js|css|js_link|css_link|html)$!;

    push @LJ::INCLUDE_RAW => [$type, $code];
}

sub res_template_includes {
    my $ret = shift;
    my %loaded;
    if (LJ::is_enabled('templates_from_stat')) {
        my $time = time;
        my $lang = LJ::Lang::current_language();
        my $src  = $LJ::IS_SSL? $LJ::SSLROOT : $LJ::STATPREFIX;
           $src .= '/tmpl/??';

        my $timestamp = int(time() / $LJ::TEMPLATES_UPDATE_TIME);
        foreach my $extension ('.tmpl', '.jqtmpl') {
            my $mtime = 0;

            my @files_list = map {
                    local $_ = $_;
                    s{^} {../};
                    my $lmtime = _file_modtime($_, $time);
                    $mtime = $lmtime if $lmtime > $mtime;
                    s{^.*?templates/} {};
                    $_
                } grep {
                    -1 != index $_, $extension
                } @LJ::SITEWIDE_TEMPLATES, @LJ::INCLUDE_TEMPLATE;

            $ret .= @files_list
                ? join (join(',', @files_list),
                    qq{<script type="text/javascript" src="$src},
                    qq{?v=$mtime&tm=$timestamp;uselang=$lang"></script>\n})
                : '';
        }
    } else {
        foreach my $template (@LJ::SITEWIDE_TEMPLATES, @LJ::INCLUDE_TEMPLATE) {
            my $path = [split m{(?<!\\)/}, $template];
            my $file = pop @$path;
            my ($type, $filter);

            shift @$path if $path->[0] eq 'templates';

            $path     = join '/', $LJ::TEMPLATE_BASE, @$path;
            my $fpath = join '/', $path, $file;

            -f $fpath             or warn 'Missing template '. $fpath and next;
            $loaded{lc $fpath}++ and next;

            for ($file) {
                m{\.jqtmpl$}i and do {
                    $type   = 'JQuery.tmpl';
                    $filter = 'jqtmpl';
                };

                m{\.tmpl$}i   and do {
                     $type   = 'HTML::Template';
                    $filter = $LJ::TEMPLATE_FILTER;
                };
            }

            $type or next;

            my $data = LJ::Response::CachedTemplate->new(
                file               => $file,
                path               => $path,
                type               => $type,
                translate          => $LJ::TEMPLATE_TRANSLATION,
                filter             => $filter,
            );

            # Create template id
            my $key = $template;
            $key =~ s{(?<!\\)/} {-}g;
            $key =~ s{\.(?:jq)?tmpl$} {}g;

            # TODO: </script> in template can ruin your day
            if ( $LJ::IS_DEV_SERVER ) {
                $ret .= sprintf q{<script type="text/plain"
                    id="%s"
                    data-path="%s"
                    data-file="%s"
                    data-type="%s"
                    data-filter="%s"
                    data-translation="%s">},
                $key, $path, $file, $type, $filter, $LJ::TEMPLATE_TRANSLATION;
                $ret .= $data->raw_output();
                $ret .= '</script>';
            } else {
                $ret .= sprintf q{<script type="text/plain" id="%s">}, $key;
                $ret .= $data->raw_output();
                $ret .= '</script>';
            }

            # Let js know about template
            $ret .= sprintf q{<script>LJ.UI.registerTemplate('%s', '%s', '%s');</script>}, $key, $key, $LJ::TEMPLATE_TRANSLATION;
        }
    }

    return $ret;
}

sub res_includes {
    my $opts = shift || {};
    my $only_needed = $opts->{only_needed}; # do not include defaults
    my $site_anyway = $opts->{site_anyway}; # Site anyway
    my $is_mobile   = $opts->{is_mobile};   # m.livejournal.com

    my $no_sitewide_css = $opts->{no_sitewide_css}; # do not include @LJ::SITEWIDE_CSS

    # TODO: automatic dependencies from external map and/or content of files,
    # currently it's limited to dependencies on the order you call LJ::need_res();
    my $ret = "";
    my $ret_js  = "";
    my $ret_css = "";
    my %libs    = (); ## pseudo files.
    my $do_concat = $LJ::IS_SSL ? $LJ::CONCAT_RES_SSL : $LJ::CONCAT_RES;
    my $now     = time();

    # all conditions must be complete here
    # example: cyr/non-cyr flag changed at settings page
    unless ($only_needed) {
        LJ::run_hooks('sitewide_resources', {
            is_mobile       => $is_mobile,
            no_sitewide_css => $no_sitewide_css,
        });
    }
 
    # use correct root and prefixes for SSL pages
    my ($siteroot, $imgprefix, $statprefix, $jsprefix, $wstatprefix);
    if ($LJ::IS_SSL) {
        $siteroot    = $LJ::SSLROOT;
        $imgprefix   = $LJ::SSLIMGPREFIX;
        $statprefix  = $LJ::SSLSTATPREFIX;
        $jsprefix    = $LJ::SSLJSPREFIX;
        $wstatprefix = $LJ::SSLWSTATPREFIX;
    }
    else {
        $siteroot    = $LJ::SITEROOT;
        $imgprefix   = $LJ::IMGPREFIX;
        $statprefix  = $LJ::STATPREFIX;
        $jsprefix    = $LJ::JSPREFIX;
        $wstatprefix = $LJ::WSTATPREFIX;
    }

    # add jQuery.tmpl templates
    if ( $opts->{'only_tmpl'} ) {
        return res_template_includes;
    }

    # include standard JS info
    unless ( $only_needed && !$site_anyway) {
        # find current journal
        my $journal_base = '';
        my $journal      = '';
        my $ju;

        if (LJ::Request->is_inited) {
            my $journalid = LJ::Request->notes('journalid');

            $ju = LJ::load_userid($journalid) if $journalid;

            if ($ju) {
                $journal_base = $ju->journal_base;
                $journal = $ju->{user};
            }
        }

        my %journal_info;
        if (my $journalu = LJ::get_active_journal()) {
            %journal_info = $journalu->info_for_js;
            $journal_base ||= $journalu->journal_base;
            $journal      ||= $journalu->username;
        }

        my $remote = LJ::get_remote();
        my $hasremote = $remote ? 1 : 0;
        my $remote_is_suspended = $remote && $remote->is_suspended ? 1 : 0;

        # ctxpopup prop
        my $ctxpopup = 1;
        $ctxpopup = 0 if $remote and not $remote->prop("opt_ctxpopup");
        $ctxpopup = 0 if LJ::Request->get_param('ctxpp') eq 'no';

        # poll for esn inbox updates?
        my $inbox_update_poll = $LJ::DISABLED{inbox_update_poll} ? 0 : 1;

        # are media embeds enabled?
        my $embeds_enabled = $LJ::DISABLED{embed_module} ? 0 : 1;

        # esn ajax enabled?
        my $esn_async = LJ::conf_test($LJ::DISABLED{esn_ajax}) ? 0 : 1;

        # remote is maintainer in current journal
        my $remote_is_maintainer = ($remote && $remote->can_manage($ju)) ? 1 : 0;

        my $default_copyright = $remote ? ($remote->prop("default_copyright") || 'P') : 'P';
        my $locale = LJ::Lang::current_language();
        $locale = $locale eq 'debug'? $locale : LJ::lang_to_locale($locale);

        my %comm_access = ();
        if ($ju && $ju->is_community && $remote && $remote->is_validated) {
            my @c_acc = LJ::get_comm_settings ($ju);
            $comm_access{'membership'} = $c_acc[0] if scalar @c_acc;
        }

        my (undef, $country) = LJ::GeoLocation->ip_class ();
        my $ljentry = LJ::Request->notes('ljentry') || ''; # url
        my %site = (
                imgprefix                => "$imgprefix",
                siteroot                 => "$siteroot",
                statprefix               => "$statprefix",
                jsonrpcprefix            => "$LJ::JSON_RPC_PREFIX",
                logprefix                => "$LJ::JSLOGPREFIX",
                picsUploadDomain         => $LJ::PICS_UPLOAD_DOMAIN,
                currentJournalBase       => "$journal_base",
                currentJournal           => "$journal",
                currentEntry             => $ljentry,
                has_remote               => $hasremote,
                remote_can_track_threads => $remote && $remote->get_cap('track_thread'),
                remote_is_suspended      => $remote_is_suspended,
                remote_is_maintainer     => $remote_is_maintainer,
                remote_is_identity       => $remote && $remote->is_identity,
                remote_is_sup            => LJ::SUP->is_remote_sup()? 1 : 0,
                ctx_popup                => $ctxpopup,
                inbox_update_poll        => $inbox_update_poll,
                media_embed_enabled      => $embeds_enabled,
                esn_async                => $esn_async,
                server_time              => int time(),
                templates_update_time    => int $LJ::TEMPLATES_UPDATE_TIME || 600,
                remoteJournalBase        => $remote && $remote->journal_base,
                remoteUser               => $remote && $remote->user,
                remoteLocale             => LJ::lang_to_locale( LJ::Lang::get_remote_lang() ),
                locale                   => $locale,
                pics_production          => LJ::is_enabled('pics_production'),
                v                        => stc_0_modtime($now),
                country                  => $country,
                counterprefix            => "$LJ::LJCOUNTER_URI_BASE",
                %comm_access,
        );
        $site{default_copyright} = $default_copyright if LJ::is_enabled('default_copyright', $remote);
        $site{is_dev_server} = 1 if $LJ::IS_DEV_SERVER;
        $site{inbox_unread_count} = $remote->notification_inbox->unread_count if $remote and LJ::is_enabled('inbox_unread_count_in_head');

        LJ::run_hooks('add_to_site_js', \%site) unless ($only_needed);

        LJ::need_var(D => \%LJ::JS_D) unless exists $LJ::JSVAR{'D'};

        my $site_params = LJ::js_dumper(\%site);

        my $to_json = sub {
            return 'null' unless $_[0];

            $_[0] = LJ::JSON->to_json($_[0]);

            # LJSUP-12854: Fix escape for Site object
            $_[0] =~ s{(?<=</s)(?=cript)} {"+"}gi;

            return $_[0];
        };

        my $journal_info_json = $to_json->(\%journal_info);
        my $jsml_out          = $to_json->(\%LJ::JSML);
        my $jsvar_out         = $to_json->(\%LJ::JSVAR);
        my $remote_info       = $to_json->(get_remote_info());
        my $journal_info      = $to_json->(get_journal_info());
        my $entry_info        = $to_json->(get_entry_info());
        my $ljlive_info       = $to_json->(get_ljlive_info());

        my $site_version      = LJ::ejs($LJ::CURRENT_VERSION);

        $ret_js .= <<"";
            <script type="text/javascript">
                Site = window.Site || {};
                Site.ml_text = $jsml_out;
                Site.page = $jsvar_out;
                Site.page.template = {};
                Site.page.ljlive = $ljlive_info;
                Site.timer = +(new Date());
                Site.remote = $remote_info;
                Site.journal = $journal_info;
                Site.entry = $entry_info;
                (function(){
                    var p = $site_params, i;
                    for (i in p) Site[i] = p[i];
                })();
                Site.current_journal = $journal_info_json;
                Site.version = '$site_version';
           </script>


    } ## / unless $only_needed

    my $host = LJ::Request->header_in("Host");

    # foreign domain case
    if (not $host =~ /\.$LJ::DOMAIN(:\d+)?$/ and not $opts->{only_css}) {
        my $remote = LJ::get_remote();

        #first part of cross-domain auth
        if ( $remote ) {

            my $hash_userid = sha1_base64($remote->{_session}->{userid} . $LJ::DOMAIN_JOURNALS_SECRET_KEY);
            $ret_js .= qq|
                <script type="text/javascript">
                    lj_user = '$hash_userid';
                </script>
            |;
        }
        else {
             $ret_js .= qq|
                <script type="text/javascript">
                    lj_user = 0;
                </script>
            |;
        }

        $ret_js .= qq|
            <script src="$siteroot/misc/get_auth_js.bml"></script>
        |;

        my $curl = LJ::Session::_current_url();
           $curl =~ m|^https?://(.+?)/|i;

        my $domain = $1;

        my $sign_time = time;
        my $curl_sign = LJ::run_hook('sign_set_domain_session_redirect' => $curl, $sign_time);

        $curl = LJ::eurl($curl);

        $ret_js .= qq|
        <script type="text/javascript">
            if( lj_user !== 0 && lj_master_user === 0 ) {
                window.location = "http://$domain/misc/clear_domain_session.bml?return=$curl";
            } else if ( lj_master_user !== 0 && lj_master_user !== lj_user ) {
                window.location = "${LJ::SITEROOT}/misc/get_domain_session.bml?return=$curl&sign=$curl_sign&t=$sign_time";
            }
        </script>\n|;
    }

    my $minify_js_flag = LJ::Request->get_param("minify_js") eq 0;

    my %list;   # type -> condition -> args -> [list of files];
    my %oldest; # type -> condition -> args -> $oldest
    my $add = sub {
        my ($type, $what, $modtime, $opts) = @_;

        $opts ||= {};
        my $condition = $opts->{condition};
        $condition ||= ''; ## by default, no condtion is present

        my $args = $opts->{args};
        $args ||= '';

        # in the concat-res case, we don't directly append the URL w/
        # the modtime, but rather do one global max modtime at the
        # end, which is done later in the tags function.
        unless ($do_concat){
            $what .= "?v=$modtime";
            $what .= "&minify_js=0" if $minify_js_flag and $type =~ /^js/;
        }

        push @{$list{$type}{$condition}{$args} ||= []}, $what;
        $oldest{$type}{$condition}{$args} = $modtime if $modtime > $oldest{$type}{$condition}{$args};
    };

    ## Replace sources with appropriate libraries
    unless ($only_needed){
        my %libs = ();
        @LJ::NEEDED_RES =
            grep { length }
            map  {
                my $res = $_;
                ## is the key part of library/package
                my $library;
                if ($library = ($LJ::JS_SOURCE_MAP_REV{$_} || $LJ::CSS_SOURCE_MAP_REV{$_})){
                    $res = $libs{$library}++ ? '' : $library;
                }
                $res;
            } @LJ::NEEDED_RES;
    }

    my $mtime0 = stc_0_modtime($now);

    foreach my $key (@LJ::NEEDED_RES) {
        my $path;
        my $mtime;
        my $library;

        ## for libraries check mtime of all files
        my $library_files;
        if ($library_files = ($LJ::JS_SOURCES_MAP{$key} || $LJ::CSS_SOURCES_MAP{$key})){
            $library = $key;
            $libs{$library} = 1;
            foreach my $file (@$library_files){
                my $lmtime = _file_modtime($key, $now);
                $mtime = $lmtime if $lmtime > $mtime;
            }
        }

        $mtime = $mtime0 unless defined $mtime;

        $path = $key;

        if ($path =~ m!^js/(.+)!) {
            $add->("js$library", $1, $mtime, $LJ::NEEDED_RES{$key} || {});
        }
        elsif ($path =~ /\.css$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stccss$library", $2, $mtime, $LJ::NEEDED_RES{$key});
        }
        elsif ($path =~ /\.js$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stcjs", $2, $mtime, $LJ::NEEDED_RES{$key});
        }
    }

    foreach my $key (@LJ::NEEDED_RES_SEPARATE) {
        my $path;
        my $mtime;
        my $library;

        $path = $key;

        if ($path =~ m!^js/(.+)!) {
            $add->("js2$library", $1, $mtime, $LJ::NEEDED_RES_SEPARATE{$key} || {});
        }
        elsif ($path =~ /\.css$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stccss$library", $2, $mtime, $LJ::NEEDED_RES_SEPARATE{$key});
        }
        elsif ($path =~ /\.js$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stcjs", $2, $mtime, $LJ::NEEDED_RES_SEPARATE{$key});
        }
    }

    my $tags = sub {
        my ($type, $template) = @_;
        return unless $list{$type};
        return if $opts->{only_css}
                and $template =~ /^<script/;
        return if $opts->{only_js}
                and $template =~ /^<link/;

        my $minify_js = ($minify_js_flag and $template =~ /^<script/)
                        ? '&minify_js=0' : "";

        foreach my $cond (sort {length($a) <=> length($b)} keys %{ $list{$type} }) {
            foreach my $args (sort {length($a) <=> length($b)} keys %{ $list{$type}{$cond} }) {
                my $list = $list{$type}{$cond}{$args};
                my $start = ($cond) ? "<!--[if $cond]>" : "";
                my $end = ($cond) ? "<![endif]-->\n" : "\n";

                if ($do_concat) {
                    my $csep = join(',', @$list);
                    my $mtime = $oldest{$type}{$cond}{$args};

                    ## shorten long (>20 symbols) links
                    if (!$LJ::DISABLED{shorten_long_stat_links} and length ($csep) > 100 and not LJ::Request->get_param('fullstatlinks')) {
                        my $short = LJ::URI::Shortener->uri_to_id($csep);
                        $csep = "." . $short if $short;
                    }

                    ## stc/0 is the empty file.
                    ## touch-ing it changes ?v= param for all included res.
                    my $mtime_base = stc_0_modtime($now);
                    $mtime = $mtime_base if $mtime_base > $mtime;

                    $csep .= "?v=" . $mtime;
                    if ($minify_js){
                        $csep .= $minify_js;
                    }
                    my $inc = $template;
                    $inc =~ s/__+/??$csep/;
                    $inc =~ s/##/$args/;
                    $ret .= $start . $inc . $end;
                }
                else {
                    foreach my $item (@$list) {
                        my $inc = $template;
                        $inc =~ s/__+/$item/;
                        $inc =~ s/##/$args/;
                        $ret .= $start . $inc . $end;
                    }
                }
            }
        }
    };


    ## To ensure CSS files are downloaded in parallel, always include external CSS before external JavaScript.
    ##  (C) http://code.google.com/speed/page-speed/
    ##
    unless ($opts->{only_js}) {
        $ret .= $ret_css;
        foreach my $library (@LJ::CSS_SOURCES_ORDER){ ## add libraries in strict order
            next unless $libs{$library};
            $tags->("stccss$library",  "<link rel=\"stylesheet\" type=\"text/css\" href=\"$statprefix/___\" ##>");
        }
        $tags->("stccss",  "<link rel=\"stylesheet\" type=\"text/css\" href=\"$statprefix/___\" ##>");
        $tags->("wstccss", "<link rel=\"stylesheet\" type=\"text/css\" href=\"$wstatprefix/___\" ##>");
    }

    unless ($opts->{only_css}) {
        $ret .= $ret_js;
        foreach my $library (@LJ::JS_SOURCES_ORDER){ ## add libraries in strict order
            next unless $libs{$library};
            $tags->("js$library", "<script type=\"text/javascript\" src=\"$jsprefix/___\"></script>");
        }

        $tags->("common_js", "<script type=\"text/javascript\" src=\"$jsprefix/___\"></script>");
        $tags->("js",      "<script type=\"text/javascript\" src=\"$jsprefix/___\"></script>");
        $tags->("js2",      "<script type=\"text/javascript\" src=\"$jsprefix/___\"></script>");
        $tags->("stcjs",   "<script type=\"text/javascript\" src=\"$statprefix/___\"></script>");
        $tags->("wstcjs",  "<script type=\"text/javascript\" src=\"$wstatprefix/___\"></script>");
    }

    return $ret if $only_needed;

    # add raw js/css
    foreach my $inc (@LJ::INCLUDE_RAW) {
        my ( $type, $code ) = @$inc;

        if ($type eq 'js'){
            $ret .= qq|<script type="text/javascript">\r\n$code</script>\r\n| unless $opts->{only_css};
        }
        elsif ($type eq 'css'){
            $ret .= qq|<style>\r\n$code</style>\n| unless $opts->{only_js};
        }
        elsif ( $type eq 'js_link' ) {
            $ret .= qq{<script type="text/javascript" src="$code"></script>\r\n} unless $opts->{only_css};
        }
        elsif ( $type eq 'css_link' ) {
            $ret .= qq{<link rel="stylesheet" type="text/css" href="$code" >} unless $opts->{only_js};
        }
        elsif ( $type eq 'html' ) {
            $ret .= $code unless $opts->{only_css}; ## add raw html to js part
        }
    }


    return $ret;
}

sub get_remote_info {
    my $remote  = LJ::get_remote();
    my $journal = LJ::get_active_journal();

    return unless $remote;

    return {
        ($journal ? (
            alias           => $remote->get_alias($journal),
            is_friend       => LJ::JSON->to_boolean($remote->is_friend($remote)),
            is_subscribedon => LJ::JSON->to_boolean($remote->is_mysubscription($remote)),
        ) : ()),

        # Personal info
        id               => $remote->id,
        username         => $remote->username,
        profile_url      => $remote->profile_url,
        journal_url      => $remote->journal_url,
        userhead_url     => $remote->userhead_url,
        journal_title    => $remote->journal_title,
        display_username => $remote->display_username,

        # Flags
        is_sup           => LJ::JSON->to_boolean($remote->is_sup),
        is_paid          => LJ::JSON->to_boolean($remote->is_paid),
        is_personal      => LJ::JSON->to_boolean($remote->is_personal),
        is_identity      => LJ::JSON->to_boolean($remote->is_identity),
        is_suspended     => LJ::JSON->to_boolean($remote->is_suspended),
        is_community     => LJ::JSON->to_boolean($remote->is_community),
    };
}

sub get_journal_info {
    my $remote  = LJ::get_remote();
    my $journal = LJ::get_active_journal();

    return unless $journal;

    return {
        ($remote ? (
            is_member       => LJ::JSON->to_boolean($journal->is_member($remote)),
            is_friend       => LJ::JSON->to_boolean($remote->is_friend($journal)),
            is_invite_sent  => LJ::JSON->to_boolean($remote->is_invite_sent($journal)),
            is_subscribedon => LJ::JSON->to_boolean($remote->is_mysubscription($journal)),
        ) : ()),

        # Personal info
        id               => $journal->id,
        username         => $journal->username,
        profile_url      => $journal->profile_url,
        journal_url      => $journal->journal_url,
        userhead_url     => $journal->userhead_url,
        journal_title    => $journal->journal_title,
        display_username => $journal->display_username,

        # Flags
        is_paid          => LJ::JSON->to_boolean($journal->is_paid),
        is_personal      => LJ::JSON->to_boolean($journal->is_personal),
        is_identity      => LJ::JSON->to_boolean($journal->is_identity),
        is_suspended     => LJ::JSON->to_boolean($journal->is_suspended),
        is_community     => LJ::JSON->to_boolean($journal->is_community),
    };
}

sub get_entry_info {
    my $entry = LJ::Entry->new_from_url(LJ::Request->current_page_url());
    return unless $entry && $entry->valid;

    my $journal = $entry->journal;
    return unless $journal;

    my $poster = $entry->poster;
    return unless $poster;

    return {
        ditemid => $entry->ditemid,
        title   => $entry->subject_raw,
        poster  => $poster->user,
        journal => $journal->user,
    }
}

# Discovery times branding 
sub get_ljlive_info {
    my $bodyref = '';

    LJ::run_hooks('ljtimes_rebranding' => {
        'location' => 'reskining_html',
        'bodyref'  => \$bodyref,
    });

    return {
        ($bodyref ? (branding_template => $bodyref) : ()),
        is_enabled => LJ::JSON->to_boolean(LJ::Discovery::Times->is_enabled), 
    }
}

# Returns HTML of a dynamic tag could given passed in data
# Requires hash-ref of tag => { url => url, value => value }
sub tag_cloud {
    my ($tags, $opts) = @_;

    # find sizes of tags, sorted
    my @sizes = sort { $a <=> $b } map { $tags->{$_}->{'value'} } keys %$tags;

    # remove duplicates:
    my %sizes = map { $_, 1 } @sizes;
    @sizes = sort { $a <=> $b } keys %sizes;

    my @tag_names = sort keys %$tags;

    my $percentile = sub {
        my $n = shift;
        my $total = scalar @sizes;
        for (my $i = 0; $i < $total; $i++) {
            next if $n > $sizes[$i];
            return $i / $total;
        }
    };

    my $base_font_size = 8;
    my $font_size_range = $opts->{font_size_range} || 25;
    my $ret .= "<div id='tagcloud' class='tagcloud'>";
    my %tagdata = ();
    foreach my $tag (@tag_names) {
        my $tagurl = $tags->{$tag}->{'url'};
        my $ct     = $tags->{$tag}->{'value'};
        my $pt     = int($base_font_size + $percentile->($ct) * $font_size_range);
        $ret .= "<a ";
        $ret .= "id='taglink_$tag' " unless $opts->{ignore_ids};
        $ret .= "href='" . LJ::ehtml($tagurl) . "' style='font-size: ${pt}pt;'><span>";
        $ret .= LJ::ehtml($tag) . "</span></a>\n";

        # build hash of tagname => final point size for refresh
        $tagdata{$tag} = $pt;
    }
    $ret .= "</div>";

    return $ret;
}

sub get_next_ad_id {
    return ++$LJ::REQ_GLOBAL{'curr_ad_id'};
}

##
## Function LJ::check_page_ad_block. Return answer (true/false) to question:
## Should we show ad of this type on this page.
## Args: uri of the page and orient of the ad block (e.g. 'App-Confirm')
##
sub check_page_ad_block {
    my $uri = shift;
    my $orient = shift;

    # The AD_MAPPING hash may contain code refs
    # This allows us to choose an ad based on some logic
    # Example: If LJ::did_post() show 'App-Confirm' type ad
    my $ad_mapping = LJ::run_hook('get_ad_uri_mapping', $uri) ||
        LJ::conf_test($LJ::AD_MAPPING{$uri});

    return 1 if $ad_mapping eq $orient;
    return 1 if ref($ad_mapping) eq 'HASH' && $ad_mapping->{$orient};
    return;
}

# returns a hash with keys "layout" and "theme"
# "theme" is empty for S1 users
sub get_style_for_ads {
    my $u = shift;

    my %ret;
    $ret{layout} = "";
    $ret{theme} = "";

    # Values for custom layers, default themes, and S1 styles
    my $custom_layout = "custom_layout";
    my $custom_theme = "custom_theme";
    my $default_theme = "default_theme";
    my $s1_prefix = "s1_";

    if ($u->prop('stylesys') == 2) {
        my %style = LJ::S2::get_style($u);
        my $public = LJ::S2::get_public_layers();

        # get layout
        my $layout = $public->{$style{layout}}->{uniq}; # e.g. generator/layout
        $layout =~ s/\/\w+$//;

        # get theme
        # if the theme id == 0, then we have no theme for this layout (i.e. default theme)
        my $theme;
        if ($style{theme} == 0) {
            $theme = $default_theme;
        } else {
            $theme = $public->{$style{theme}}->{uniq}; # e.g. generator/mintchoc
            $theme =~ s/^\w+\///;
        }

        $ret{layout} = $layout ? $layout : $custom_layout;
        $ret{theme} = $theme ? $theme : $custom_theme;
    } else {
        my $view = LJ::Request->notes->{view};
        $view = "lastn" if $view eq "";

        if ($view =~ /^(?:friends|day|calendar|lastn)$/) {
            my $pubstyles = LJ::S1::get_public_styles();
            my $styleid = $u->prop("s1_${view}_style");

            my $layout = "";
            if ($pubstyles->{$styleid}) {
                $layout = $pubstyles->{$styleid}->{styledes}; # e.g. Clean and Simple
                $layout =~ s/\W//g;
                $layout =~ s/\s//g;
                $layout = lc $layout;
                $layout = $s1_prefix . $layout;
            }

            $ret{layout} = $layout ? $layout : $s1_prefix . $custom_layout;
        }
    }

    return %ret;
}

sub get_search_term {
    my $uri = shift;
    my $search_arg = shift;

    my %search_pages = (
        '/interests.bml' => 1,
        '/directory.bml' => 1,
        '/multisearch.bml' => 1,
    );

    return "" unless $search_pages{$uri};

    my $term = "";
    my $args = LJ::Request->args;
    if ($uri eq '/interests.bml') {
        if ($args =~ /int=([^&]+)/) {
            $term = $1;
        }
    } elsif ($uri eq '/directory.bml') {
        if ($args =~ /int_like=([^&]+)/) {
            $term = $1;
        }
    } elsif ($uri eq '/multisearch.bml') {
        $term = $search_arg;
    }

    # change +'s to spaces
    $term =~ s/\+/ /;

    return $term;
}


# this returns ad html given a search string
sub search_ads {
    my %opts = @_;

    return '' if LJ::conf_test($LJ::DISABLED{content_ads});

    return '' unless $LJ::USE_JS_ADCALL_FOR_SEARCH;

    my $remote = LJ::get_remote();

    return '' unless LJ::run_hook('should_show_ad', {
        ctx  => 'app',
        user => $remote,
        type => '',
    });

    return '' unless LJ::run_hook('should_show_search_ad');

    my $query = delete $opts{query} or croak "No search query specified in call to search_ads";
    my $count = int(delete $opts{count} || 1);
    my $adcount = int(delete $opts{adcount} || 3);

    my $adid = get_next_ad_id();
    my $divid = "ad_$adid";

    my @divids = map { "ad_$_" } (1 .. $count);

    my %adcall = (
        u      => join(',', map { $adcount } @divids), # how many ads to show in each
        r      => rand(),
        q      => $query,
        id     => join(',', @divids),
        p      => 'lj',
        add    => 'lj_content_ad',
        remove => 'lj_inactive_ad',
    );

    if ($remote) {
        $adcall{user} = $remote->id;
    }

    my $adparams = LJ::encode_url_string(\%adcall,
        [
            sort { length $adcall{$a} <=> length $adcall{$b} }
            grep { length $adcall{$_} }
            keys %adcall
        ]
    );

    # allow 24 bytes for escaping overhead
    $adparams = substr($adparams, 0, 1_000);

    my $url = $LJ::ADSERVER . '/google/?' . $adparams;

    my $adhtml;

    my $adcall = '';
    if (++$LJ::REQ_GLOBAL{'curr_search_ad_id'} == $count) {
        $adcall .= qq { <script charset="utf-8" id="ad${adid}s" src="$url"></script>\n };
        $adcall .= qq { <script language="javascript" src="http://www.google.com/afsonline/show_afs_ads.js"></script> };
    }

    $adhtml = qq {
        <div class="lj_inactive_ad" id="$divid" style="clear: left;">
            $adcall
        </div>
        <div class='lj_inactive_ad clear'>&nbsp;</div>
    };

    return $adhtml;
}

sub get_ads {
    LJ::run_hook('ADV_get_ad_html', @_);
}

sub should_show_ad {
    LJ::run_hook('ADV_should_show_ad', @_);
}

# modifies list of interests (appends tags of sponsored questions to the list)
# sponsored question may be taken
#   1. from argument of function: $opts = { extra => {qotd => ...} },
#   2. from URL args of /update.bml page (/update.bml?qotd=123)
#   3. from first displayed entry on the page
sub modify_interests_for_adcall {
    my $opts = shift;
    my $list = shift;

    my $qotd;
    if (ref $opts->{extra} && $opts->{extra}->{qotd}) {
        $qotd = $opts->{extra}->{qotd};
    } elsif (LJ::Request->is_inited && LJ::Request->notes('codepath') eq 'bml.update' && $BMLCodeBlock::GET{qotd}) {
        $qotd = $BMLCodeBlock::GET{qotd};
    } elsif (@LJ::SUP_LJ_ENTRY_REQ) {
        my ($journalid, $posterid, $ditemid) = @{ $LJ::SUP_LJ_ENTRY_REQ[0] };
        my $entry = LJ::Entry->new(LJ::load_userid($journalid), ditemid => $ditemid);
        if ($entry && $entry->prop("qotdid")) {
            $qotd = $entry->prop("qotdid");
        }
    }

    if ($qotd) {
        $qotd = LJ::QotD->get_single_question($qotd) unless ref $qotd;
        my $tags = LJ::QotD->remove_default_tags($qotd->{tags});
        if ($tags && $qotd->{is_special} eq "Y") {
            unshift @$list, $tags;
        }
    }
}

# this function will filter out blocked interests, as well filter out interests which
# cause the
sub interests_for_adcall {
    my $u = shift;
    my %opts = @_;

    # base ad call is 300-400 bytes, we'll allow interests to be around 600
    # which is unlikely to go over IE's 1k URL limit.
    my $max_len = $opts{max_len} || 600;

    my $int_len = 0;

    my @interest_list = $u ? $u->notable_interests(100) : ();

    modify_interests_for_adcall(\%opts, \@interest_list);

    return join(',',
                grep {

                    # not a blocked interest
                    ! defined $LJ::AD_BLOCKED_INTERESTS{$_} &&

                    # and we've not already got over 768 bytes of interests
                    # -- +1 is for comma
                    ($int_len += length($_) + 1) <= $max_len;

                    } @interest_list
                );
}

# for use when calling an ad from BML directly
sub ad_display {
    my %opts = @_;

    # can specify whether the wrapper div on the ad is used or not
    my $use_wrapper = defined $opts{use_wrapper} ? $opts{use_wrapper} : 1;

    my $ret = LJ::ads(%opts);

    my $extra;
    if ($ret =~ /"ljad ljad(.+?)"/i) {
        # Add a badge ad above all skyscrapers
        # First, try to print a badge ad in journal context (e.g. S1 comment pages)
        # Then, if it doesn't print, print it in user context (e.g. normal app pages)
        if ($1 eq "skyscraper") {
            $extra = LJ::ads(type => $opts{'type'},
                             orient => 'Journal-Badge',
                             user => $opts{'user'},
                             search_arg => $opts{'search_arg'},
                             force => '1' );
            $extra = LJ::ads(type => $opts{'type'},
                             orient => 'App-Extra',
                             user => $opts{'user'},
                             search_arg => $opts{'search_arg'},
                             force => '1' )
                        unless $extra;
        }
        $ret = $extra . $ret
    }

    my $pagetype = $opts{orient};
    $pagetype =~ s/^BML-//;
    $pagetype = lc $pagetype;

    $ret = $opts{below_ad} ? "$ret<br />$opts{below_ad}" : $ret;
    $ret = $ret && $use_wrapper ? "<div class='ljadwrapper-$pagetype'>$ret</div>" : $ret;

    return $ret;
}

sub control_strip {
    my %opts = @_;

    return LJ::ControlStrip->render($opts{user});
}

sub control_strip_js_inject {
    my %opts = @_;

    LJ::ControlStrip->need_res(%opts);
}

sub journal_js_inject {
    LJ::need_journal_res();

    LJ::need_res(qw(
        js/s2.js
        js/esn.js
        js/jquery/jquery.lj.confirmbubble.js
        js/jquery/jquery.lj.ljcut.js
    ));

    LJ::run_hooks('extra_journal_js');
}

# For the Rich Text Editor
# Set JS variables for use by the RTE
sub rte_js_vars {
    my ($remote) = @_;

    my $ret = '';
    # The JS var canmakepoll is used by fckplugin.js to change the behaviour
    # of the poll button in the RTE.
    # Also remove any RTE buttons that have been set to disabled.
    my $canmakepoll = "true";
    $canmakepoll = "false" if ($remote && !LJ::get_cap($remote, 'makepoll'));
    $ret .= "<script type='text/javascript'>\n";
    $ret .= "    var RTEdisabled = new Array();\n";
    LJ::need_var(makepoll => $canmakepoll eq 'true'? 1 : 0);
    my $rte_disabled = $LJ::DISABLED{rte_buttons} || {};
    foreach my $key (keys %$rte_disabled) {
        $ret .= "    RTEdisabled['$key'] = true;" if $rte_disabled->{$key};
    }
    $ret .= qq^
        var canmakepoll = $canmakepoll;

        function removeDisabled(ToolbarSet) {
            for (var i=0; i<ToolbarSet.length; i++) {
                for (var j=0; j<ToolbarSet[i].length; j++) {
                    if (RTEdisabled[ToolbarSet[i][j]] == true) ToolbarSet[i].splice(j,1);
                }
            }
        }
    </script>^;

    return $ret;
}

# returns a placeholder link
sub placeholder_link {
    my (%opts) = @_;

    my $placeholder_html = LJ::ejs_all(delete $opts{placeholder_html} || '');
    my $width  = delete $opts{width}  || 100;
    my $height = delete $opts{height} || 100;
    my $link   = delete $opts{link}   || '';
    my $img    = delete $opts{img}    || "$LJ::IMGPREFIX/videoplaceholder.png?v=8209";

    $width -= 2;
    $height -= 2;

    return qq {
            <a href="$link" class="b-mediaplaceholder b-mediaplaceholder-video } . ( $opts{remove_video_sizes} ? '" ' : ' b-mediaplaceholder-good" style="width:' . $width . 'px;height:' . $height . 'px;"' ) . ( $width ? qq~ data-width="$width"~ : '' ) . ( $height ? qq~ data-height="$height"~: '' ) . qq{ onclick="return LiveJournal.placeholderClick(this, '$placeholder_html')">
                <span class="b-mediaplaceholder-outer">
                    <span class="b-mediaplaceholder-inner">
                        <i class="b-mediaplaceholder-pic"></i>
                        <span class="b-mediaplaceholder-label b-mediaplaceholder-view">} . ($opts{no_encode} ? Encode::decode_utf8(LJ::Lang::ml("mediaplaceholder.viewvideo")) : Encode::encode_utf8(Encode::decode_utf8(LJ::Lang::ml("mediaplaceholder.viewvideo")))) . qq{</span>
                        <span class="b-mediaplaceholder-label b-mediaplaceholder-loading">} . ($opts{no_encode} ? Encode::decode_utf8(LJ::Lang::ml("mediaplaceholder.loading")) : Encode::encode_utf8(Encode::decode_utf8(LJ::Lang::ml("mediaplaceholder.loading")))) . qq{</span>
                    </span>
                </span>
            </a>
        }; 
} #"

# Returns replacement for lj-replace tags
sub lj_replace {
    my $key = shift;
    my $attr = shift;

    # Return hook if hook output not undef
    if (LJ::are_hooks("lj-replace_$key")) {
        my $replace = LJ::run_hook("lj-replace_$key");
        return $replace if defined $replace;
    }

    # Return value of coderef if key defined
    my %valid_keys = ( 'first_post' => \&lj_replace_first_post );

    if (my $cb = $valid_keys{$key}) {
        die "$cb is not a valid coderef" unless ref $cb eq 'CODE';
        return $cb->($attr);
    }

    return undef;
}

# Replace for lj-replace name="first_post"
sub lj_replace_first_post {
    return unless LJ::is_web_context();
    return BML::ml('web.lj-replace.first_post', {
                   'update_link' => "href='$LJ::SITEROOT/update.bml'",
                   });
}

# this returns the right max length for a VARCHAR(255) database
# column.  but in HTML, the maxlength is characters, not bytes, so we
# have to assume 3-byte chars and return 80 instead of 255.  (80*3 ==
# 240, approximately 255).  However, we special-case Russian where
# they often need just a little bit more, and make that 100.  because
# their bytes are only 2, so 100 * 2 == 200.  as long as russians
# don't enter, say, 100 characters of japanese... but then it'd get
# truncated or throw an error.  we'll risk that and give them 20 more
# characters.
sub std_max_length {
    my $lang = eval { BML::get_language() };
    return 80  if !$lang || $lang =~ /^en/;
    return 100 if $lang =~ /\b(hy|az|be|et|ka|ky|kk|lt|lv|mo|ru|tg|tk|uk|uz)\b/i;
    return 80;
}

# Common challenge/response JavaScript, needed by both login pages and comment pages alike.
# Forms that use this should onclick='return sendForm()' in the submit button.
# Returns true to let the submit continue.
$LJ::COMMON_CODE{'chalresp_js'} = qq{
<script language="JavaScript" type="text/javascript">
    <!--
function sendForm (formid, checkuser)
{
    if (formid == null) formid = 'login';
    // 'checkuser' is the element id name of the username textfield.
    // only use it if you care to verify a username exists before hashing.

    if (! document.getElementById) return true;
    var loginform = document.getElementById(formid);
    if (! loginform) return true;
    if(document.getElementById('prop_current_location')){
        if(document.getElementById('prop_current_location').value=='detecting...') document.getElementById('prop_current_location').value='';
    }
    // Avoid accessing the password field if there is no username.
    // This works around Opera < 7 complaints when commenting.
    if (checkuser) {
        var username = null;
        for (var i = 0; username == null && i < loginform.elements.length; i++) {
            if (loginform.elements[i].id == checkuser) username = loginform.elements[i];
        }
        if (username != null && username.value == "") return true;
    }

    if (! loginform.password || ! loginform.login_chal || ! loginform.login_response) return true;
    var pass = loginform.password.value;
    var chal = loginform.login_chal.value;
    var res = MD5(chal + MD5(pass));
    loginform.login_response.value = res;
    loginform.password.value = "";  // dont send clear-text password!
    return true;
}
// -->
</script>
};

# Common JavaScript function for auto-checking radio buttons on form
# input field data changes
$LJ::COMMON_CODE{'autoradio_check'} = q{
<script language="JavaScript" type="text/javascript">
    <!--
    /* If radioid exists, check the radio button. */
    function checkRadioButton(radioid) {
        if (!document.getElementById) return;
        var radio = document.getElementById(radioid);
        if (!radio) return;
        radio.checked = true;
    }
// -->
</script>
};

sub initial_body_html {
    my $after_body_open = '';
    LJ::run_hooks('insert_html_after_body_open', \$after_body_open);
    return $after_body_open;
}

# returns HTML which should appear before </body>
sub final_body_html {
    my $before_body_close = "";
    LJ::run_hooks('insert_html_before_body_close', \$before_body_close);

    if (LJ::Request->notes('codepath') eq "bml.talkread" || LJ::Request->notes('codepath') eq "bml.talkpost") {
        my $journalu = LJ::load_userid(LJ::Request->notes('journalid'));
        unless (LJ::Request->notes('bml_use_scheme') eq 'lynx') {
            my $graphicpreviews_obj = LJ::graphicpreviews_obj();
            $before_body_close .= $graphicpreviews_obj->render($journalu);
        }
    }

    return $before_body_close;
}

# return a unique per pageview string based on the remote's unique cookie
sub pageview_unique_string {
    my $cached_uniq = $LJ::REQ_GLOBAL{pageview_unique_string};
    return $cached_uniq if $cached_uniq;

    my $uniq = LJ::UniqCookie->current_uniq . time() . LJ::rand_chars(8);
    $uniq = Digest::SHA1::sha1_hex($uniq);

    $LJ::REQ_GLOBAL{pageview_unique_string} = $uniq;
    return $uniq;
}

# <LJFUNC>
# name: LJ::site_schemes
# class: web
# des: Returns a list of available BML schemes.
# args: none
# return: array
# </LJFUNC>
sub site_schemes {
    my @schemes = @LJ::SCHEMES;
    LJ::run_hooks('modify_scheme_list', \@schemes);
    @schemes = grep { !$_->{disabled} } @schemes;
    return @schemes;
}

# returns a random value between 0 and $num_choices-1 for a particular uniq
# if no uniq available, just returns a random value between 0 and $num_choices-1
sub ab_testing_value {
    my %opts = @_;

    return $LJ::DEBUG{ab_testing_value} if defined $LJ::DEBUG{ab_testing_value};

    my $num_choices = $opts{num_choices} || 2;
    my $uniq = LJ::UniqCookie->current_uniq;

    my $val;
    if ($uniq) {
        $val = unpack("I", $uniq);
        $val %= $num_choices;
    } else {
        $val = int(rand($num_choices));
    }

    return $val;
}

# sets up appropriate js for journals that need a special statusvis message at the top
# returns some js that must be added onto the journal page's head
sub statusvis_message_js {
    my $u = shift;

    return "" unless $u;

    my $statusvis = $u->statusvis;
    return "" unless $statusvis =~ /^[LMO]$/;

    my $statusvis_full = "";
    $statusvis_full = "locked" if $statusvis eq "L";
    $statusvis_full = "memorial" if $statusvis eq "M";
    $statusvis_full = "readonly" if $statusvis eq "O";

    LJ::need_res("js/statusvis_message.js");

    LJ::need_var(StatusvisMessage => LJ::Lang::ml("statusvis_message.$statusvis_full"));
}

sub needlogin_redirect_url {
    my $uri = LJ::Request->uri;
    if (my $qs = LJ::Request->args) {
        $uri .= "?" . $qs;
    }
    $uri = LJ::eurl($uri);

    return "$LJ::SITEROOT/login.bml?returnto=$uri";
}

sub needlogin_redirect {
    return LJ::Request->redirect( LJ::needlogin_redirect_url() );
}

sub get_body_class_for_service_pages {
    my %opts = @_;

    my @classes;
    push @classes, @{ $opts{'classes'} } if $opts{'classes'};
    push @classes, (LJ::get_remote()) ? 'logged-in' : 'logged-out';
    push @classes, 'p-ssl' if $LJ::IS_SSL;

    my $uri  = LJ::Request->uri;
    my $host = LJ::Request->header_in("Host");
    if ($uri =~ m!^/index\.bml$!) {
        push @classes, "index-page";
    } elsif ($uri =~ m{^/stats/latest\.bml$}) {
        push @classes, "p-lenta";
    } elsif ($uri =~ m!^/shop(/.*)?$!) {
        push @classes, "shop-page";
    } elsif ($uri =~ m!^/pics(/.*)?$!) {
        if (LJ::_is_pics_branding_active()) {
            my ($user) = $host =~ /([\w\-]{1,15})\.\Q$LJ::DOMAIN\E$/;
            $user = LJ::get_remote () || LJ::load_user ($user);
            if ($user && LJ::Pics::Album->list( 'userid' => $user->userid )) {
                ## photos exists
                push @classes, "b-foto-branding-view";
            } else {
                ## no photos
                push @classes, "b-foto-branding-promo";
            }
        } else {
            ## branding is not active
            push @classes, "framework-page";
        }
    } elsif ($uri =~ m!^/browse(/.*)?$!) {
        push @classes, "catalogue-page";
    } elsif (
        $uri =~ m!^/games(/.*)?$!
        || $host eq "$LJ::USERAPPS_SUBDOMAIN.$LJ::DOMAIN"
        || $uri =~ m!^/adv(/.*)?$!
    ) {
        push @classes, 'framework-page';
    } elsif ($uri =~ m|^/friendstimes|
             or ($host =~ m!^(\w+)\.\Q$LJ::USER_DOMAIN\E$!
                 and $LJ::IS_USER_DOMAIN->{$1}
                 and $uri =~ m!/([\w-]+)/friendstimes/?!
                 )
    ){
        push @classes, "p-friendstimes";
    } elsif (LJ::Request->notes ("homepage_v2")) {
        push @classes, "p-home";
    }
    if ($uri =~ m!^/(?:update|editjournal)\.bml!) {
        push @classes, "b-foto-branding"
            if LJ::_is_pics_branding_active();
    }

    LJ::run_hooks( 'get_body_class_for_service_pages', \@classes );

    return join(" ", @classes);
}

# Add some javascript language strings
sub need_string {
    my @strings = @_;

    for my $item (@strings) {
        # When comes as a hash ref, should be treated as name => value
        if(ref $item eq 'HASH') {
            for my $key (keys %$item) {
                $LJ::JSML{$key} = $item->{$key};
            }
        # When handling array ref, name the ml by the value of the second element
        } elsif(ref $item eq 'ARRAY') {
            $LJ::JSML{$$item[1]} = LJ::Lang::ml($$item[0]);
        # If scalar - use the ml named this way
        } else {
            $LJ::JSML{$item} = LJ::Lang::ml($item);
        }
    }
}

# Add some javascript variables
sub need_var {
    my %vars;

    # Our arguments are hash ref
    if (@_ == 1 and ref $_[0] and ref $_[0] eq 'HASH') {
        %vars = %{$_[0]};
    # List of key-value pairs otherwise
    } else {
        while (my ($k, $v) = splice @_, 0, 2) {
            $vars{$k} = $v;
        }
    }

    while (my ($k, $v) = each %vars) {
        warn 'JS Variable override: '. $k
            if $LJ::IS_DEV_SERVER and exists $LJ::JSVAR{$k};

        $LJ::JSVAR{$k} = $v;
    }
}

sub set_remote_language {
    my ($lang) = @_;

    my $l      = LJ::Lang::get_lang($lang);
    my $remote = LJ::get_remote();

    my $exptime = 0;

    my $cval = $l->{'lncode'} . '/' . time();

    # if logged in, change userprop and make cookie expiration
    # the same as their login expiration
    if ($remote) {
        $remote->set_prop( 'browselang' => $l->{lncode} );

        if ( $remote->{'_session'}->{'exptype'} eq 'long' ) {
            $exptime = $remote->{'_session'}->{'timeexpire'};
        }
    }

    # set cookie
    LJ::Request->set_cookie( 'langpref' => $cval, 'expires' => $exptime );

    # set language through BML so it will apply immediately
    BML::set_language( $l->{'lncode'} );

    return;
}

sub priv_for_page {
    my $url = shift;
    return undef unless $url;
    return undef unless $LJ::PAGE_PRIVILEGES{$url};
    my $priv = $LJ::PAGE_PRIVILEGES{$url}{'priv'};
    my $arg = $LJ::PAGE_PRIVILEGES{$url}{'arg'};
    return "$priv:$arg";
}

# http://ogp.me/, https://dev.twitter.com/docs/cards
sub metadata_html {
    my $meta = shift;
    return '' unless $meta;

    # https://dev.twitter.com/docs/cards/app-installs-and-deep-linking
    (my $iosScheme .= $meta->{'url'}) =~ s/^(http)/lj/;

    my %tags = (
                'og:title'       => $meta->{'title'}       || '(no title)',
                'og:description' => $meta->{'description'} || '',
                'og:image'       => $meta->{'image'},
        'og:type'        => 'website',
        'og:url'         => $meta->{'url'} || $LJ::SITEROOT,
        'twitter:card'   => 'summary',
        'twitter:site'   => '@livejournal',

        'twitter:app:name:iphone' => 'LiveJournal',
        "twitter:app:id:iphone"   => '383091547',
        "twitter:app:url:iphone"  => $iosScheme,
        "twitter:app:name:ipad"   => 'LiveJournal',
        "twitter:app:id:ipad"     => '383091547',
        "twitter:app:url:ipad"    => $iosScheme
                );

    my $html = '';
    foreach my $k ( sort keys %tags ) {
        my $property_ehtml = LJ::ehtml($k);
        my $content_ehtml  = LJ::ehtml( $tags{$k} );
        $html .=
            qq{<meta property="$property_ehtml" content="$content_ehtml" />};
    }

    return $html;
}


1;
