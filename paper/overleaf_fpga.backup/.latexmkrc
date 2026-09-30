# Use optional project-local TeX dependencies on hosts with a minimal TeX Live.
# Full TeX Live and Overleaf installations use their normal package paths.
if (-d '_outputs/texmf') {
    use Cwd qw(abs_path);
    my $outputs = abs_path('_outputs');
    $ENV{'TEXMFHOME'} = "$outputs/texmf";
    $ENV{'TEXMFCONFIG'} = "$outputs/texmf-config";
    $ENV{'TEXMFVAR'} = "$outputs/texmf-var";
}

$out_dir = '_outputs';
$pdf_mode = 1;
