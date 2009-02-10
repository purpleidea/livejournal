package LJ::Widget::FindFriendsInExistingUsers;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub ajax { 1 }
sub authas { 1 }

sub need_res { qw( stc/widgets/search.css stc/widgets/friendsfinder.css js/jobstatus.js) }

sub handle_post { }

sub render_body {
    my $class = shift;
    my $ret;

    my @search_opts = (
        'user' => $class->ml('.widget.search.username'),
        'email' => $class->ml('.widget.search.email'),
        'aolim' => $class->ml('.widget.search.aim'),
        'icq' => $class->ml('.widget.search.icq'),
        'jabber' => $class->ml('.widget.search.jabber'),
        'msn' => $class->ml('.widget.search.msn'),
        'yahoo' => $class->ml('.widget.search.yahoo'),
        'skype' => $class->ml('widget.search.skype'),
        'google_talk' => $class->ml('widget.search.google_talk'),
    );

    $ret .= "<div class='mailfinder exists'>";
    $ret .= "<h4>" . $class->ml('.widget.search.existingtitle') . "</h4>\n";
    $ret .= $class->ml('widget.search.note');
    $ret .= $class->start_form( id => $class->input_prefix . "_user_search");
    $ret .= "<fieldset><label for='existuser'>" . $class->ml('.widget.search.title') . "</label>";
    $ret .= $class->html_text(name => 'q', 'class' => 'mailbox', 'size' => 30, id => 'existuser' ) . " ";
    $ret .= $class->html_select({name => 'type', selected => 'int'}, @search_opts) . " </fieldset>";    
    $ret .= "<div class='ffind'>" . $class->html_submit( button => $class->ml('.widget.search.submit'), { class => "btn" });
    $ret .= "<span id='" . $class->input_prefix . "_errors' class='find_err'></span>";
    $ret .= "</div>";
    $ret .= $class->end_form;
    $ret .= "<div id='" . $class->input_prefix . "_ajax_status'></div><br/>";
    $ret .= "</div>";

    return $ret;
}

sub js {
    my $self = shift;

    my $init_text = $self->ml('widget.search.init_text');
    my $query_error = $self->ml('widget.search.query_error');
    my $empty_email = $self->ml('widget.search.empty.email');
    my $empty_name = $self->ml('widget.search.empty.username');
    my $empty_IM_handle = $self->ml('widget.search.empty.IM_handle');
    my $validate_email = $self->ml('widget.search.not_valid.email');
    my $validate_username = $self->ml('widget.search.not_valid.username');
    my $validate_IM_error = $self->ml('widget.search.not_valid.IM_handle');
    my $validate_IM_aim = $self->ml('widget.search.not_valid.IM_handle.aim');
    my $validate_IM_icq = $self->ml('widget.search.not_valid.IM_handle.icq');
    my $validate_IM_jabber = $self->ml('widget.search.not_valid.IM_handle.jabber');
    my $validate_IM_msn = $self->ml('widget.search.not_valid.IM_handle.msn');
    my $validate_IM_yahoo = $self->ml('widget.search.not_valid.IM_handle.yahoo');
    my $validate_IM_skype = $self->ml('widget.search.not_valid.IM_handle.skype');
    my $validate_IM_google_talk = $self->ml('widget.search.not_valid.IM_handle.google_talk');

    qq [
        initWidget: function() {
            this.form = \$('Widget[FindFriendsInExistingUsers]_user_search');
            
            DOM.addEventListener(this.form, 'submit', function (e) {
                Event.stop(e);
                if (this.validate())
                    this.AskAddressBook(\$('Widget[FindFriendsInExistingUsers]_user_search'));
            }.bind(this))
        },

        AskAddressBook: function(form) {
            var type  = this.form['Widget[FindFriendsInExistingUsers]_type'].value;
            this.query = this.form['Widget[FindFriendsInExistingUsers]_q'].value;

            \$('Widget[FindFriendsInExistingUsers]_errors').innerHTML = '';
            \$('Widget[FindFriendsInExistingUsers]_ajax_status').innerHTML = '$init_text';

            var req = {
                        data: HTTPReq.formEncoded({q: this.query, type: type}),
                        method: 'POST',
                        url: LiveJournal.getAjaxUrl('multisearch'),
                        onData: this.import_handle.bind(this),
                        onError: this.import_error.bind(this)
                      }

            HTTPReq.getJSON(req);
        },

        import_error: function(msg) {
            \$('Widget[FindFriendsInExistingUsers]_ajax_status').innerHTML = '';
            \$('Widget[FindFriendsInExistingUsers]_errors').innerHTML = msg;
        },

        import_handle: function(info) {
            if (info.error) {
                return this.import_error(info.error);
            }

            if (info.status != 'success') {
                return this.import_error('$query_error');
            }

            \$('Widget[FindFriendsInExistingUsers]_ajax_status').innerHTML = info.result;
        },

        validate: function() {
            var v = this.form['Widget[FindFriendsInExistingUsers]_q'].value.trim(),
                r,
                rex_email = /^(("[\\w-\\s]+")|([\\w-]+(?:\\.[\\w-]+)*)|("[\\w-\\s]+")([\\w-]+(?:\\.[\\w-]+)*))(@((?:[\\w-]+\\.)*\\w[\\w-]{0,66})\\.([a-z]{2,6}(?:\\.[a-z]{2})?)\$)|(@\\[?((25[0-5]\\.|2[0-4][0-9]\\.|1[0-9]{2}\\.|[0-9]{1,2}\\.))((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[0-9]{1,2})\\.){2}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[0-9]{1,2})\\]?\$)/i,
                select = this.form['Widget[FindFriendsInExistingUsers]_type'],
                error_valid = '$validate_IM_error',
                error_empty = '$empty_IM_handle',
                not_valid_txt = {
                    user: '$validate_username',
                    email: '$validate_email',
                    aolim: '$validate_IM_aim',
                    icq: '$validate_IM_icq',
                    jabber: '$validate_IM_jabber',
                    msn: '$validate_IM_msn',
                    yahoo: '$validate_IM_yahoo',
                    skype: '$validate_IM_skype',
                    google_talk: '$validate_IM_google_talk'
                },
                client = select.options[select.selectedIndex].value;

            switch (client) {
                case 'user':
                    r = /^[0-9a-z_-]{1,15}\$/i;
                    error_empty = '$empty_name';
                    break;
                case 'email':
                    error_empty = '$empty_email';
                    r = rex_email;
                    break;
                case 'skype':
                    r = /^[a-z0-9_.-]+\$/i;
                    break;
                case 'lastfm':
                    r = /^[a-z][_a-z0-9-]{1,20}\$/i; // /^[a-z][_a-z0-9\-]{1,14}\$/i - in last.fm website
                    break;
                case 'icq':
                    r = /^\\d+\$/;
                    break;
                case 'gizmo':
                    r = /^[0-9a-z_-]+\$/i;
                    break;
            }

            if (!v) {
                this.import_error(error_empty);
                return false;
            }

            if (r && !r.test(v)) {
                if (not_valid_txt[client])
                    error_valid = not_valid_txt[client];

                this.import_error(error_valid);
                return false;
            }

            return true;
        },

        onRefresh: function (data) {
            this.initWidget();
        }
    ];
}

1;
