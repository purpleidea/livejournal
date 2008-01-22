package LJ::Widget::VerticalSummary;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Vertical );

sub need_res { qw( stc/widgets/verticalsummary.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $vertical = $opts{vertical};
    die "Invalid vertical object passed to widget." unless $vertical;

    my $subcats = join(" | ", map { "<a href='" . $_->url . "'>" . $_->display_name . "</a>" } $vertical->children);
    my @entries = $vertical->entries( start => 0, limit => 2 );
    my $ret;

    $ret .= "<div class='vertsummary-outer'>";

    my $heading_class = $subcats ? "" : " class='vertsummary-nosubcats'";
    $ret .= "<h2$heading_class><a href='" . $vertical->url . "'>";
    $ret .= "<span class='vertsummary-verticalname'>" . $vertical->display_name . "</span> &raquo;";
    $ret .= "</a></h2>";

    $ret .= "<div class='vertsummary-inner'>";

    if ($subcats) {
        $ret .= "<p class='vertsummary-subcats'>";
        $ret .= $class->ml('widget.verticalsummary.subcats', { subcats => $subcats });
        $ret .= "</p>";
    }

    my $count = 1;
    foreach my $entry (@entries) {
        $ret .= "<table class='vertsummary-entries' cellspacing='7' cellpadding='0'>";
        $ret .= "<tr valign='top'><td class='vertsummary-userpic'>";

        if ($entry->userpic) {
            $ret .= $entry->userpic->imgtag_percentagesize(0.35);
        } else {
            $ret .= LJ::run_hook('no_userpic_html', percentage => 0.35 );
        }

        $ret .= "</td><td class='vertsummary-content'>";

        $ret .= "<p class='vertsummary-subject'><a href='" . $entry->url . "'><strong>";
        $ret .= LJ::Widget::VerticalEntries->entry_subject( entry => $entry );
        $ret .= "</strong></a></p>";

        $ret .= "<p class='vertsummary-poster'>";
        $ret .= $class->ml('widget.verticalsummary.byuser', { user => "<a href='" . $entry->poster->journal_base . "/'>" . $entry->poster->user . "</a>" });
        unless ($entry->posterid == $entry->journalid) {
            $ret .= " " . $class->ml('widget.verticalsummary.injournal', { user => "<a href='" . $entry->journal->journal_base . "/'>" . $entry->journal->user . "</a>" });
        }
        $ret .= "</p>";

        my $secondsago = time() - $entry->logtime_unix;
        my $posttime = LJ::ago_text($secondsago);
        $ret .= "<p class='vertsummary-posttime'>" . $class->ml('widget.verticalsummary.posttime', { posttime => $posttime }) . "</p>";

        $ret .= "</td></tr>";
        $ret .= "</table>";
        $ret .= "<hr />" unless $count == @entries;

        $count++;
    }

    $ret .= "</div></div>";

    return $ret;
}

1;
