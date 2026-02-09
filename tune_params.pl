#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Find;

#
# 使用說明 (繁體中文)
# 1) 只收集（不執行指令、不調參）：
#    perl tune_params.pl --collect
# 2) 不調參（建立輸出 + 執行指令 + 收集資料）：
#    perl tune_params.pl --no-tune
# 3) 全流程自動調參（建立輸出 + 執行 + 收集 + 調參）：
#    perl tune_params.pl --auto
# 4) 參數對應：
#    - 使用 %default_param_map 決定「輸出欄位 -> 參數」
#    - 沒列在 %default_param_map 的欄位不會被調整
# 5) 收集檔案/數據關鍵字：
#    - @collect_file_keywords 決定要收集的檔名（關鍵字）
#    - @collect_data_keys 決定要收集的數據 key（空則用 %default_param_map 的 key）
# 6) 指定只調哪些參數：
#    - USER CONFIG 中 @select_params
#    - 或 CLI：--params D_p,F_p
#
# =========================
# 使用者設定 (可改)
# =========================
# 輸入
my $target_file = 'target.csv';
my $param_tuning_file = 'n1.sh'; # 參數要被替換的檔案
my $output_dir = 'output';

# 輸出資料夾修改規則（矩陣 / 笛卡爾拆分）
# 注意：這裡的 file 也會被複製到每個 output 子資料夾
my @modifications = (
    { file => 'n1.sh', keyword => 'D=5.4', new_lines => ['D=5.4', 'D=3.8', 'D=1.1'], lines => [3] },
    { file => 'n2.sh', keyword => 'A=0.7', new_lines => ['A=2', 'A=4'], lines => [3] }
);

# 每個 output 子資料夾要執行的指令
# 注意：若 param_tuning_file 改名，這裡也要同步更新
my @run_commands = (
    "sh n1.sh > all.txt",
);

# 收集檔案關鍵字（檔名包含即可）
# 若留空，會收集所有檔案
my @collect_file_keywords = ('all.txt');

# 收集數據關鍵字（key 名稱）
# 若留空，會使用 %default_param_map 的 key
my @collect_data_keys = ();

# 內建對應（輸出欄位 -> 參數）
# 可在這裡自訂，例如 D_1 => D1_p, D_2 => D2_p
my %default_param_map = (
    D_2 => 'D2_p',
    E => 'E_p',
    F => 'F_p',
);

# 輸出
my $out_file = 'output/results/tuned_params.csv';
my $report_file = 'output/results/tuning_report.csv';
my $data_file = 'output/results/merged_data.csv';

# 調參行為
my $join_key = 'File_Path';
my $tol = 0.05;
my $step = 1.02;
my $min_param = -1e6;
my $max_param = 1e6;
my $model = 'add';
my $max_rounds = 10;
my @select_params = ();

# 流程預設
my $auto = 0;
my $collect = 0;
my $no_tune = 0;
my $help = 0;

# =========================
# 內部參數 (不建議改)
# =========================
my $step_set = 0;
my $params_cli = '';
my %opt_seen;

sub set_opt {
    my ($name, $setter) = @_;
    return sub {
        my ($opt_name, $value) = @_;
        $opt_seen{$name} = 1;
        $setter->($value) if $setter;
    };
}

# =========================
# CLI 解析
# =========================
GetOptions(
    'data=s'        => set_opt('data', sub { $data_file = $_[0]; }),
    'target=s'      => set_opt('target', sub { $target_file = $_[0]; }),
    'params=s'      => set_opt('params', sub { $params_cli = $_[0]; }),
    'join-key=s'    => set_opt('join-key', sub { $join_key = $_[0]; }),
    'tol=f'         => set_opt('tol', sub { $tol = $_[0]; }),
    'step=f'        => set_opt('step', sub { $step = $_[0]; $step_set = 1; }),
    'min-param=f'   => set_opt('min-param', sub { $min_param = $_[0]; }),
    'max-param=f'   => set_opt('max-param', sub { $max_param = $_[0]; }),
    'out=s'         => set_opt('out', sub { $out_file = $_[0]; }),
    'report=s'      => set_opt('report', sub { $report_file = $_[0]; }),
    'model=s'       => set_opt('model', sub { $model = $_[0]; }),
    'tuning-file=s' => set_opt('tuning-file', sub { $param_tuning_file = $_[0]; }),
    'template=s'    => set_opt('template', sub { $param_tuning_file = $_[0]; }),
    'auto'          => set_opt('auto', sub { $auto = 1; }),
    'no-tune'       => set_opt('no-tune', sub { $no_tune = 1; }),
    'collect'       => set_opt('collect', sub { $collect = 1; }),
    'max-rounds=i'  => set_opt('max-rounds', sub { $max_rounds = $_[0]; }),
    'help'          => set_opt('help', sub { $help = 1; }),
) or die "Usage: $0 --collect|--no-tune|--auto [options]\nUse --help for details.\n";

sub print_help {
    print <<'EOF';
Usage:
  perl tune_params.pl --collect [--data path]
  perl tune_params.pl --no-tune [--data path] [--tuning-file file | --template file]
  perl tune_params.pl --auto [auto options]

Modes (exactly one is required):
  --collect   Collect only. Read .txt files under output recursively. No command execution, no tuning.
  --no-tune   Build output folders + run commands + collect data. No tuning.
  --auto      Build output folders + run commands + collect + tuning loop.

Repeated key collection:
  Repeated base key lines are indexed by appearance order (e.g. D=... -> D_1, D_2, D_3...).
  Collector scans all key[:=]value fragments in each line, and ignores non-target keys.
  If map uses explicit indexed keys (D_1,D_2), source should still use base key lines D=...
  and explicit indexed source lines are ignored for indexed families.

Mode / option matrix (strict):
  collect:
    --collect --data
  no-tune:
    --no-tune --data --tuning-file --template
  auto:
    --auto --data --target --out --report --params --model --tol --step
    --min-param --max-param --max-rounds --join-key --tuning-file --template

If an option is not allowed for the selected mode, the script fails fast.

Examples:
  perl tune_params.pl --collect
  perl tune_params.pl --no-tune
  perl tune_params.pl --auto
EOF
}

sub detect_mode {
    my @modes = ();
    push @modes, 'collect' if $collect;
    push @modes, 'no-tune' if $no_tune;
    push @modes, 'auto' if $auto;
    die "Mode required. Use exactly one of --collect, --no-tune, --auto.\n" if @modes == 0;
    die "Mode conflict. Use exactly one of --collect, --no-tune, --auto.\n" if @modes > 1;
    return $modes[0];
}

sub validate_mode_options {
    my ($mode, $seen_ref) = @_;
    my %allowed_by_mode = (
        'collect' => { map { $_ => 1 } qw(collect data) },
        'no-tune' => { map { $_ => 1 } qw(no-tune data tuning-file template) },
        'auto'    => { map { $_ => 1 } qw(auto data target params join-key tol step min-param max-param out report model tuning-file template max-rounds) },
    );

    my $allowed = $allowed_by_mode{$mode} || {};
    for my $opt (sort keys %$seen_ref) {
        next if $opt eq 'help';
        next if $allowed->{$opt};
        die "Option '--$opt' is not allowed in --$mode mode.\n";
    }
}

# =========================
# CSV 解析（簡易 CSV parser，支援引號）
# =========================
sub parse_csv_line {
    my ($line) = @_;
    chomp $line;
    $line =~ s/\r//g;
    my @fields;
    my $field = '';
    my $in_quotes = 0;
    my @chars = split //, $line;
    for (my $i = 0; $i < @chars; $i++) {
        my $c = $chars[$i];
        if ($in_quotes) {
            if ($c eq '"') {
                if ($i + 1 < @chars && $chars[$i + 1] eq '"') {
                    $field .= '"';
                    $i++;
                } else {
                    $in_quotes = 0;
                }
            } else {
                $field .= $c;
            }
        } else {
            if ($c eq ',') {
                push @fields, $field;
                $field = '';
            } elsif ($c eq '"') {
                $in_quotes = 1;
            } else {
                $field .= $c;
            }
        }
    }
    push @fields, $field;
    return @fields;
}

# =========================
# CSV 讀寫輔助（讀 CSV 成 hash array）
# =========================
sub read_csv {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!";
    my $header_line = <$fh>;
    die "Empty CSV: $file\n" unless defined $header_line;
    my @header = parse_csv_line($header_line);
    my @rows;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*$/;
        my @vals = parse_csv_line($line);
        my %row;
        for (my $i = 0; $i < @header; $i++) {
            $row{$header[$i]} = defined $vals[$i] ? $vals[$i] : '';
        }
        push @rows, \%row;
    }
    close $fh;
    return (\@header, \@rows);
}

sub csv_escape {
    my ($v) = @_;
    $v = '' unless defined $v;
    if ($v =~ /[",\n]/) {
        $v =~ s/"/""/g;
        return '"' . $v . '"';
    }
    return $v;
}

# =========================
# 數學輔助（平均、幾何平均、夾住範圍）
# =========================
sub is_number {
    my ($v) = @_;
    return defined $v && $v =~ /^-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?$/;
}

sub geom_mean {
    my (@vals) = @_;
    return undef unless @vals;
    my $sum = 0;
    my $count = 0;
    for my $v (@vals) {
        next unless defined $v;
        next if $v <= 0;
        $sum += log($v);
        $count++;
    }
    return undef if $count == 0;
    return exp($sum / $count);
}

sub mean {
    my (@vals) = @_;
    return undef unless @vals;
    my $sum = 0;
    my $count = 0;
    for my $v (@vals) {
        next unless defined $v;
        $sum += $v;
        $count++;
    }
    return undef if $count == 0;
    return $sum / $count;
}

sub clamp {
    my ($v, $lo, $hi) = @_;
    return $lo if $v < $lo;
    return $hi if $v > $hi;
    return $v;
}

# =========================
# 檔案輔助（讀寫檔案、確保資料夾）
# =========================
sub read_file {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!";
    local $/ = undef;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub write_file {
    my ($file, $content) = @_;
    open my $fh, '>', $file or die "Cannot write $file: $!";
    print $fh $content;
    close $fh;
}

sub ensure_parent_dir {
    my ($path) = @_;
    my $dir = dirname($path);
    return if $dir eq '.' || $dir eq '';
    make_path($dir) unless -d $dir;
}

# =========================
# 模板替換輔助（參數字串 -> 數值）
# =========================
sub format_val {
    my ($v) = @_;
    return sprintf("%.12g", $v);
}

sub apply_template {
    my ($template, $param_values) = @_;
    my $content = $template;
    for my $p (sort { length($b) <=> length($a) } keys %$param_values) {
        my $val = format_val($param_values->{$p});
        $content =~ s/\b\Q$p\E\b/$val/g;
    }
    return $content;
}

# =========================
# 使用者參數篩選（解析 --params）
# =========================
sub parse_param_filter {
    my ($value) = @_;
    return () unless defined $value;
    my @parts = split /[,\s]+/, $value;
    @parts = grep { $_ ne '' } @parts;
    return @parts;
}

sub build_files_to_copy {
    my %seen;
    my @files;
    for my $mod (@modifications) {
        my $file = $mod->{file};
        next unless defined $file && $file ne '';
        next if $seen{$file}++;
        push @files, $file;
    }
    if (defined $param_tuning_file && $param_tuning_file ne '') {
        if (!$seen{$param_tuning_file}++) {
            push @files, $param_tuning_file;
        }
    }
    die "No files to copy. Configure \@modifications or param_tuning_file.\n" unless @files;
    my %dest_seen;
    for my $src (@files) {
        my $dest = basename($src);
        if (exists $dest_seen{$dest} && $dest_seen{$dest} ne $src) {
            die "Duplicate output filename '$dest' from '$dest_seen{$dest}' and '$src'.\n";
        }
        $dest_seen{$dest} = $src;
    }
    return @files;
}

# =========================
# 輸出資料夾準備 (multi_fix)
# 產生笛卡爾拆分資料夾並複製/修改檔案
# =========================
sub modify_content {
    my ($content, $modifications) = @_;
    my @lines = split /\n/, $content;

    foreach my $mod (@$modifications) {
        my ($keyword, $new_line, $line_nums) = @$mod{qw(keyword new_line lines)};
        foreach my $line_num (@$line_nums) {
            if ($lines[$line_num - 1] =~ /\Q$keyword\E/) {
                $lines[$line_num - 1] =~ s/\Q$keyword\E/$new_line/;
            }
        }
    }

    return join "\n", @lines;
}

sub generate_combinations {
    my @arrays = @_;
    my @combinations = ([]);

    for my $array (@arrays) {
        @combinations = map {
            my $item = $_;
            map { [@$item, $_] } @$array
        } @combinations;
    }

    return @combinations;
}

sub list_output_dirs {
    my ($out_dir) = @_;
    opendir my $dh, $out_dir or die "Cannot open $out_dir: $!";
    my @dirs = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    my @full = map { "$out_dir/$_" } @dirs;
    @full = grep { -d $_ } @full;
    @full = grep { $_ !~ /\/results$/ } @full;
    return @full;
}

sub process_output_directories {
    my ($output_dir, $required_files, $commands, $only_dirs) = @_;
    die "Folder '$output_dir' invalid, Please check path.\n" unless -d $output_dir;

    my @sub_dirs = $only_dirs ? @$only_dirs : list_output_dirs($output_dir);

    my $max_processes = 10;
    my $current_processes = 0;

    foreach my $dir (@sub_dirs) {
        my $all_files_exist = 1;
        foreach my $file (@$required_files) {
            unless (-e "$dir/$file") {
                warn "Folder '$dir' lack $file, skip.\n";
                $all_files_exist = 0;
                last;
            }
        }
        next unless $all_files_exist;

        while ($current_processes >= $max_processes) {
            wait();
            $current_processes--;
        }

        my $pid = fork();
        if (!defined $pid) {
            die "Cannot generate subprocess: $!";
        } elsif ($pid == 0) {
            chdir $dir or die "Cannot enter directory: $dir";
            foreach my $cmd (@$commands) {
                my $exit_status = system($cmd);
                if ($exit_status != 0) {
                    warn "In folder: '$dir' encounter execution error: $cmd\n";
                }
            }
            exit 0;
        } else {
            $current_processes++;
        }
    }

    while (wait() != -1) {
        $current_processes--;
    }
}

sub prepare_output_dirs {
    my ($out_dir, $do_clean) = @_;
    if (-d $out_dir && $do_clean) {
        my $err;
        remove_tree($out_dir, { error => \$err });
        if ($err && @$err) {
            for my $diag (@$err) {
                my ($file, $message) = %$diag;
                warn "Failed to remove $file: $message\n";
            }
            die "Failed to remove existing output folder.\n";
        }
    }

    my %original_contents;
    my @files_to_copy = build_files_to_copy();

    foreach my $file (@files_to_copy) {
        $original_contents{$file} = read_file($file);
    }

    my @active_mods = grep {
        ref($_->{new_lines}) eq 'ARRAY' && @{$_->{new_lines}}
    } @modifications;

    my @combinations;
    if (@active_mods) {
        my @new_lines_lists = map { $_->{new_lines} } @active_mods;
        @combinations = generate_combinations(@new_lines_lists);
    } else {
        @combinations = ( [] );
    }

    foreach my $combination (@combinations) {
        my $folder_name = @active_mods
            ? join('_',
                map {
                    my $new_line = $_;
                    $new_line eq '' ? 'original' : $new_line
                } @$combination
            )
            : 'default';

        my $folder_path = "$out_dir/${folder_name}";
        make_path($folder_path) unless -d $folder_path;

        foreach my $file (keys %original_contents) {
            my @modifications_for_file;
            for my $i (0 .. $#active_mods) {
                if ($active_mods[$i]->{file} eq $file) {
                    push @modifications_for_file, {
                        keyword => $active_mods[$i]->{keyword},
                        new_line => $combination->[$i],
                        lines => $active_mods[$i]->{lines},
                    };
                }
            }
            my $modified_content = @modifications_for_file
                ? modify_content($original_contents{$file}, \@modifications_for_file)
                : $original_contents{$file};
            my $dest = basename($file);
            write_file("$folder_path/$dest", $modified_content);
        }
    }
}

# =========================
# 資料收集
# 遞迴掃 output 下 .txt，依檔名關鍵字與數據 key 產生 merged_data
# =========================
sub filename_matches_keywords {
    my ($fname, $keywords_ref) = @_;
    return 1 unless @$keywords_ref;
    for my $kw (@$keywords_ref) {
        next if !defined $kw || $kw eq '';
        return 1 if index($fname, $kw) >= 0;
    }
    return 0;
}

sub parse_indexed_key {
    my ($key) = @_;
    return unless defined $key;
    if ($key =~ /^(.+)_([1-9]\d*)$/) {
        return ($1, $2 + 0, 'underscore');
    }
    if ($key =~ /^(.+?)([1-9]\d*)$/) {
        return ($1, $2 + 0, 'plain');
    }
    return;
}

sub make_indexed_key {
    my ($base, $idx, $style) = @_;
    $style = 'plain' unless defined $style && $style ne '';
    return $style eq 'underscore' ? "${base}_${idx}" : "${base}${idx}";
}

sub extract_pairs_from_line {
    my ($line) = @_;
    return () unless defined $line;
    my @pairs;
    while ($line =~ /\b([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*([^\s,;]+)/g) {
        push @pairs, [$1, $2];
    }
    return @pairs;
}

sub natural_cmp {
    my ($a, $b) = @_;
    my @aa = ($a =~ /(\d+|\D+)/g);
    my @bb = ($b =~ /(\d+|\D+)/g);

    while (@aa && @bb) {
        my $x = shift @aa;
        my $y = shift @bb;
        my $x_num = ($x =~ /^\d+$/) ? 1 : 0;
        my $y_num = ($y =~ /^\d+$/) ? 1 : 0;

        if ($x_num && $y_num) {
            my $cmp = $x <=> $y;
            return $cmp if $cmp;
        } else {
            my $cmp = lc($x) cmp lc($y);
            return $cmp if $cmp;
        }
    }
    return (@aa <=> @bb) || (lc($a) cmp lc($b));
}

sub collect_merged_data {
    my ($out_dir, $out_csv, $file_keywords_ref, $data_keys_ref) = @_;
    die "Output folder '$out_dir' not found.\n" unless -d $out_dir;

    my @file_keywords = $file_keywords_ref ? @$file_keywords_ref : ();
    my @data_keys = $data_keys_ref ? @$data_keys_ref : ();
    my %data_allow = map { $_ => 1 } @data_keys;
    my $filter_data = @data_keys ? 1 : 0;

    my @txt_files;
    find(
        sub {
            return unless -f $_;
            return unless $_ =~ /\.txt\z/i;
            push @txt_files, $File::Find::name;
        },
        $out_dir
    );
    @txt_files = sort @txt_files;
    die "No .txt files found under '$out_dir'.\n" unless @txt_files;

    my %plain_expected;
    my %indexed_cfg_by_base;
    for my $k (@data_keys) {
        my ($base, $idx, $style) = parse_indexed_key($k);
        if (defined $base) {
            my $cfg = $indexed_cfg_by_base{$base} ||= { max => 0, style => $style };
            $cfg->{max} = $idx if $idx > $cfg->{max};
            # Prefer underscore style when mixed styles exist.
            if ($cfg->{style} ne 'underscore' && $style eq 'underscore') {
                $cfg->{style} = 'underscore';
            }
        } else {
            $plain_expected{$k} = 1;
        }
    }

    my @parsed_rows;
    my $matched_name_files = 0;
    my $dup_files = 0;
    my $missing_index_files = 0;
    my $overflow_index_files = 0;
    my %overflow_columns;

    for my $file (@txt_files) {
        my $fname = basename($file);
        next unless filename_matches_keywords($fname, \@file_keywords);
        $matched_name_files++;
        my %occ_by_key;
        open my $fh, '<', $file or die "Cannot open $file: $!";
        while (my $line = <$fh>) {
            chomp $line;
            my @pairs = extract_pairs_from_line($line);
            for my $pair (@pairs) {
                my ($key, $val) = @$pair;
                my ($maybe_base, $maybe_idx, $maybe_style) = parse_indexed_key($key);
                # Indexed families are sourced from base keys only: D=... -> D_1, D_2, ...
                if (defined $maybe_base && exists $indexed_cfg_by_base{$maybe_base}) {
                    next;
                }

                if ($filter_data) {
                    my $allow = 0;
                    $allow = 1 if $data_allow{$key};
                    $allow = 1 if exists $indexed_cfg_by_base{$key};
                    next unless $allow;
                    # Target keys are numeric metrics; non-numeric values are treated as missing.
                    next unless is_number($val);
                }

                push @{ $occ_by_key{$key} }, $val;
            }
        }
        close $fh;

        push @parsed_rows, {
            File_Path => abs_path($file) // $file,
            File_Name => $fname,
            occ       => \%occ_by_key,
        };
    }

    my %header_keys;
    my %plain_expand_max;
    for my $base (keys %plain_expected) {
        my $max_occ = 0;
        for my $pr (@parsed_rows) {
            my $n = scalar @{ $pr->{occ}{$base} // [] };
            $max_occ = $n if $n > $max_occ;
        }
        if ($max_occ > 1) {
            $plain_expand_max{$base} = $max_occ;
            for my $i (1 .. $max_occ) {
                my $k = make_indexed_key($base, $i, 'underscore');
                $header_keys{$k} = 1;
            }
        } else {
            $header_keys{$base} = 1;
        }
    }

    my %indexed_global_max_by_base;
    for my $base (keys %indexed_cfg_by_base) {
        my $cfg = $indexed_cfg_by_base{$base};
        my $max_occ = $cfg->{max};
        for my $pr (@parsed_rows) {
            my $n = scalar @{ $pr->{occ}{$base} // [] };
            $max_occ = $n if $n > $max_occ;
        }
        $indexed_global_max_by_base{$base} = $max_occ;
        for my $i (1 .. $max_occ) {
            my $k = make_indexed_key($base, $i, $cfg->{style});
            $header_keys{$k} = 1;
            if ($i > $cfg->{max}) {
                $overflow_columns{$k} = 1;
            }
        }
    }

    my @rows;
    for my $pr (@parsed_rows) {
        my %row = (
            File_Path => $pr->{File_Path},
            File_Name => $pr->{File_Name},
        );
        my $occ = $pr->{occ};

        my $file_dup = 0;
        my $file_missing = 0;
        my $file_overflow = 0;

        for my $base (keys %plain_expected) {
            my @vals = @{ $occ->{$base} // [] };
            if (exists $plain_expand_max{$base}) {
                my $expected_max = $plain_expand_max{$base};
                $file_dup = 1 if @vals > 1;
                $file_missing = 1 if @vals < $expected_max;
                for my $i (1 .. scalar(@vals)) {
                    my $k = make_indexed_key($base, $i, 'underscore');
                    $row{$k} = $vals[$i - 1];
                }
            } else {
                $row{$base} = $vals[0] if @vals;
                $file_dup = 1 if @vals > 1;
            }
        }

        for my $base (keys %indexed_cfg_by_base) {
            my @vals = @{ $occ->{$base} // [] };
            my $cfg = $indexed_cfg_by_base{$base};
            my $configured_max = $cfg->{max};
            $file_dup = 1 if @vals > 1;
            $file_missing = 1 if @vals < $configured_max;
            $file_overflow = 1 if @vals > $configured_max;

            for my $i (1 .. scalar(@vals)) {
                my $k = make_indexed_key($base, $i, $cfg->{style});
                $row{$k} = $vals[$i - 1];
            }
        }

        $dup_files++ if $file_dup;
        $missing_index_files++ if $file_missing;
        $overflow_index_files++ if $file_overflow;
        push @rows, \%row;
    }

    my @sorted_keys = sort { natural_cmp($a, $b) } keys %header_keys;
    my @header = ('File_Path', 'File_Name', @sorted_keys);
    ensure_parent_dir($out_csv);
    open my $out_fh, '>', $out_csv or die "Cannot write $out_csv: $!";
    print $out_fh join(',', map { csv_escape($_) } @header), "\n";
    for my $row (@rows) {
        my @vals = map { $row->{$_} // '' } @header;
        print $out_fh join(',', map { csv_escape($_) } @vals), "\n";
    }
    close $out_fh;

    my %stats = (
        txt_files_total    => scalar(@txt_files),
        matched_name_files => $matched_name_files,
        duplicate_base_files => $dup_files,
        missing_index_files => $missing_index_files,
        overflow_index_files => $overflow_index_files,
        overflow_columns => scalar(keys %overflow_columns),
    );
    if ($dup_files || $missing_index_files || $overflow_index_files || keys(%overflow_columns)) {
        warn "[WARN] collect summary: duplicate_base_files=$dup_files, "
           . "missing_index_files=$missing_index_files, overflow_index_files=$overflow_index_files, "
           . "overflow_columns=" . scalar(keys %overflow_columns) . "\n";
    }
    return (\@header, \@rows, \%stats);
}

# =========================
# 前置驗證（資料列、target 欄位、join key 對齊）
# =========================
sub require_non_empty_rows {
    my ($rows_ref, $source_desc) = @_;
    die "No data rows found from $source_desc.\n" unless $rows_ref && @$rows_ref;
}

sub require_target_join_column {
    my ($header_ref, $target_path) = @_;
    my %header = map { $_ => 1 } @$header_ref;
    die "Target CSV '$target_path' missing required join key column '$join_key'.\n"
        unless $header{$join_key};
}

sub warn_incomplete_indexed_map {
    my %present_by_base;
    my %max_by_base;
    for my $col (keys %default_param_map) {
        my ($base, $idx, $style) = parse_indexed_key($col);
        next unless defined $base;
        $present_by_base{$base}{$idx} = 1;
        $max_by_base{$base} = $idx
            if !exists $max_by_base{$base} || $idx > $max_by_base{$base};
    }

    my @problems;
    for my $base (sort keys %max_by_base) {
        my @missing;
        for my $i (1 .. $max_by_base{$base}) {
            push @missing, make_indexed_key($base, $i, 'underscore')
                unless $present_by_base{$base}{$i};
        }
        next unless @missing;
        push @problems, "$base missing " . join(', ', @missing);
    }

    return unless @problems;
    warn "[WARN] incomplete indexed keys in %default_param_map: " . join('; ', @problems)
       . ". Flow continues.\n";
}

sub require_auto_map_not_collapsed {
    my @collapsed;
    for my $col (sort keys %default_param_map) {
        my $param = $default_param_map{$col};
        my ($col_base, $col_idx, $col_style) = parse_indexed_key($col);
        next if defined $col_idx;

        my $param_core = defined $param ? $param : '';
        $param_core =~ s/_p$//;
        my ($p_base, $p_idx, $p_style) = parse_indexed_key($param_core);
        if (defined $p_idx) {
            push @collapsed, "$col => $param";
        }
    }
    return unless @collapsed;

    die "Auto mode is blocked by collapsed mapping entries: " . join(', ', @collapsed) . "\n"
      . "Use explicit collected columns in %default_param_map for auto tuning (e.g. D_1 => D1_p, D_2 => D2_p).\n"
      . "Current collapsed style is still allowed in --collect and --no-tune.\n";
}

sub require_auto_map_columns_present {
    my ($data_header_ref) = @_;
    my %cols = map { $_ => 1 } grep { $_ ne 'File_Path' && $_ ne 'File_Name' } @$data_header_ref;
    my @missing = grep { !exists $cols{$_} } sort keys %default_param_map;
    return unless @missing;

    my %hints;
    for my $missing_key (@missing) {
        for my $col (keys %cols) {
            if ($col =~ /^\Q$missing_key\E[1-9]\d*$/ || $col =~ /^\Q$missing_key\E_[1-9]\d*$/) {
                $hints{$col} = 1;
            }
        }
    }
    my $hint_text = '';
    if (%hints) {
        my @hint_cols = sort { natural_cmp($a, $b) } keys %hints;
        $hint_text = "Detected indexed columns in collected data: " . join(', ', @hint_cols) . ".\n";
    }

    die "Auto mode is blocked by mapping mismatch.\n"
      . "Map keys missing in collected data: " . join(', ', @missing) . "\n"
      . $hint_text
      . "Use --collect/--no-tune for collection only, or update %default_param_map to explicit collected columns (e.g. D_1 => D1_p, D_2 => D2_p).\n";
}

sub count_join_key_matches {
    my ($data_rows_ref, $target_by_key_ref) = @_;
    my $count = 0;
    for my $row (@$data_rows_ref) {
        my $key = $row->{$join_key} // '';
        next if $key eq '';
        $count++ if exists $target_by_key_ref->{$key};
    }
    return $count;
}

# =========================
# 參數對應
# 根據 %default_param_map 建立欄位->參數 與可調參數清單
# =========================
sub read_prev_params {
    my ($file, $param_list_ref) = @_;
    return {} unless -e $file;
    my ($header, $rows) = read_csv($file);
    my %by_key;
    for my $row (@$rows) {
        my $key = $row->{$join_key} // '';
        next if $key eq '';
        for my $p (@$param_list_ref) {
            my $v = $row->{$p};
            next unless is_number($v);
            $by_key{$key}{$p} = $v + 0;
        }
    }
    return \%by_key;
}

sub params_from_results {
    my ($results, $param_list_ref) = @_;
    my %by_key;
    for my $res (@$results) {
        my $key = $res->{key};
        next unless defined $key && $key ne '';
        my %vals;
        for my $p (@$param_list_ref) {
            $vals{$p} = $res->{param_value}{$p};
        }
        $by_key{$key} = \%vals;
    }
    return \%by_key;
}

sub params_changed {
    my ($prev, $curr, $param_list_ref) = @_;
    return 1 unless $prev;
    for my $p (@$param_list_ref) {
        my $a = $prev->{$p};
        my $b = $curr->{$p};
        return 1 if !defined $a || !defined $b;
        return 1 if abs($a - $b) > 1e-12;
    }
    return 0;
}

sub build_default_map {
    my ($data_header, $data_rows) = @_;
    my %map_by_key;
    my @output_cols = grep { $_ ne 'File_Path' && $_ ne 'File_Name' } @$data_header;
    for my $row (@$data_rows) {
        my $key = $row->{$join_key} // '';
        next if $key eq '';
        for my $col (@output_cols) {
            if (exists $default_param_map{$col}) {
                $map_by_key{$key}{$col} = $default_param_map{$col};
            }
        }
    }
    return \%map_by_key;
}

sub build_param_context {
    my ($data_header, $data_rows) = @_;
    my %map_by_key;
    %map_by_key = %{ build_default_map($data_header, $data_rows) };

    my %seen;
    for my $key (keys %map_by_key) {
        my $row = $map_by_key{$key};
        for my $col (@$data_header) {
            next if $col eq 'File_Path' || $col eq 'File_Name';
            my $val = $row->{$col};
            next unless defined $val && $val ne '';
            next if $val =~ /^\s*$/;
            $seen{$val} = 1;
        }
    }

    my @param_list = sort keys %seen;
    my %param_allowed = map { $_ => 1 } @param_list;

    return (\%map_by_key, \@param_list, \%param_allowed);
}

# =========================
# 核心調參（逐步更新參數直到誤差收斂）
# =========================
sub compute_params {
    my ($data_rows, $output_cols, $iter_limit, $prev_params, $target_by_key, $map_by_key, $param_list_ref, $param_allowed_ref) = @_;
    my @results;
    my $all_ok_global = 1;

    for my $row (@$data_rows) {
        my $key = $row->{$join_key} // '';
        my $target_row = $target_by_key->{$key};
        if (!$target_row) {
            warn "[WARN] target missing for key '$key'\n";
            $all_ok_global = 0;
            next;
        }
        my $map_row = $map_by_key->{$key} // {};

        my $init_val = ($model eq 'add') ? 0.0 : 1.0;
        my %param_value = map { $_ => $init_val } @$param_list_ref;
        if ($prev_params && exists $prev_params->{$key}) {
            my $prev = $prev_params->{$key};
            for my $p (@$param_list_ref) {
                if (exists $prev->{$p} && is_number($prev->{$p})) {
                    $param_value{$p} = $prev->{$p} + 0;
                }
            }
        }

        my %final_adjusted;
        my %final_error;
        my $converged = 0;
        my $used_any = 0;

        for (my $iter = 0; $iter < $iter_limit; $iter++) {
            my %ratios_for_param;
            my %deltas_for_param;
            my $all_ok = 1;
            my $any_used = 0;

            for my $col (@$output_cols) {
                my $data_val = $row->{$col};
                my $target_val = $target_row->{$col};
                my $param_name = $map_row->{$col};

                next if !defined $param_name || $param_name eq '';
                if (!$param_allowed_ref->{$param_name}) {
                    warn "[WARN] param '$param_name' not in param_list for key '$key' column '$col'\n" if $iter == 0;
                    next;
                }

                if (!is_number($data_val) || !is_number($target_val)) {
                    # Missing collected value (e.g. indexed underflow) is summarized in collect stage.
                    # Suppress per-cell noise but keep warnings for other non-numeric issues.
                    if ($iter == 0) {
                        my $missing_data = (!defined $data_val || $data_val =~ /^\s*$/);
                        if (!$missing_data) {
                            warn "[WARN] non-numeric data/target for key '$key' column '$col'\n";
                        }
                    }
                    next;
                }
                if ($model eq 'mul' && ($data_val == 0 || $target_val == 0)) {
                    warn "[WARN] zero data/target for key '$key' column '$col'\n" if $iter == 0;
                    next;
                }

                $any_used = 1;
                $used_any = 1;

                my $error;
                if ($target_val == 0) {
                    $error = abs($data_val);
                } else {
                    $error = abs($data_val / $target_val - 1);
                }
                $final_adjusted{$col} = $data_val;
                $final_error{$col} = $error;

                if ($error >= $tol) {
                    $all_ok = 0;
                }

                if ($model eq 'mul') {
                    my $ratio = $target_val / $data_val;
                    push @{ $ratios_for_param{$param_name} }, $ratio if $ratio > 0;
                } else {
                    my $delta = $target_val - $data_val;
                    push @{ $deltas_for_param{$param_name} }, $delta;
                }
            }

            if (!$any_used) {
                warn "[WARN] no adjustable outputs for key '$key'\n";
                $all_ok = 0;
                last;
            }

            if ($all_ok) {
                $converged = 1;
                last;
            }

            for my $p (@$param_list_ref) {
                if ($model eq 'mul') {
                    my $gm = geom_mean(@{ $ratios_for_param{$p} // [] });
                    next unless defined $gm;
                    my $ratio = clamp($gm, 1.0 / $step, $step);
                    my $new_val = $param_value{$p} * $ratio;
                    $new_val = clamp($new_val, $min_param, $max_param);
                    $param_value{$p} = $new_val;
                } else {
                    my $avg = mean(@{ $deltas_for_param{$p} // [] });
                    next unless defined $avg;
                    my $delta = clamp($avg, -$step, $step);
                    my $new_val = $param_value{$p} + $delta;
                    $new_val = clamp($new_val, $min_param, $max_param);
                    $param_value{$p} = $new_val;
                }
            }
        }

        if (!$converged && $used_any && !$auto) {
            warn "[WARN] did not converge for key '$key' within iter_limit=$iter_limit\n";
        }

        if (!$used_any) {
            $all_ok_global = 0;
        } else {
            for my $col (@$output_cols) {
                if (defined $final_error{$col} && $final_error{$col} >= $tol) {
                    $all_ok_global = 0;
                    last;
                }
            }
        }

        my $param_changed = params_changed($prev_params ? $prev_params->{$key} : undef, \%param_value, $param_list_ref);
        my $dir = ($key ne '') ? dirname($key) : '';

        push @results, {
            row => $row,
            key => $key,
            dir => $dir,
            param_value => \%param_value,
            final_adjusted => \%final_adjusted,
            final_error => \%final_error,
            converged => $converged,
            param_changed => $param_changed,
        };
    }

    return (\@results, $all_ok_global);
}

# =========================
# 輸出寫入（tuned_params / tuning_report / 覆蓋調參檔）
# =========================
sub write_reports {
    my ($results, $output_cols, $param_list_ref, $target_by_key) = @_;

    ensure_parent_dir($out_file);
    ensure_parent_dir($report_file);
    open my $out_fh, '>', $out_file or die "Cannot write $out_file: $!";
    open my $rep_fh, '>', $report_file or die "Cannot write $report_file: $!";

    print $out_fh join(',', map { csv_escape($_) } ('File_Path', 'File_Name', @$param_list_ref)), "\n";

    my @report_cols;
    for my $col (@$output_cols) {
        push @report_cols, "${col}_final_adjusted", "${col}_target", "${col}_final_error";
    }
    print $rep_fh join(',', map { csv_escape($_) } ('File_Path', 'File_Name', @report_cols)), "\n";

    for my $res (@$results) {
        my $row = $res->{row};
        my $param_value = $res->{param_value};
        my $final_adjusted = $res->{final_adjusted};
        my $final_error = $res->{final_error};
        my $key = $row->{$join_key} // '';
        my $target_row = $target_by_key->{$key} // {};

        my @out_row = (
            $row->{'File_Path'} // '',
            $row->{'File_Name'} // ''
        );
        push @out_row, map { $param_value->{$_} } @$param_list_ref;
        print $out_fh join(',', map { csv_escape($_) } @out_row), "\n";

        my @rep_row = (
            $row->{'File_Path'} // '',
            $row->{'File_Name'} // ''
        );
        for my $col (@$output_cols) {
            my $adj = defined $final_adjusted->{$col} ? $final_adjusted->{$col} : '';
            my $tgt = defined $target_row->{$col} ? $target_row->{$col} : '';
            my $err = defined $final_error->{$col} ? $final_error->{$col} : '';
            push @rep_row, $adj, $tgt, $err;
        }
        print $rep_fh join(',', map { csv_escape($_) } @rep_row), "\n";
    }

    close $out_fh;
    close $rep_fh;
}

sub write_templates {
    my ($results, $template_content, $changed_only, $output_name) = @_;
    for my $res (@$results) {
        next if $changed_only && !$res->{param_changed};
        my $row = $res->{row};
        my $param_value = $res->{param_value};
        my $file_path = $row->{'File_Path'};
        next unless defined $file_path && $file_path ne '';
        my $dir = dirname($file_path);
        my $out_path = "$dir/$output_name";
        my $content = apply_template($template_content, $param_value);
        write_file($out_path, $content);
    }
}

# =========================
# 主流程（串接整體流程）
# =========================
die "Unexpected positional arguments: " . join(' ', @ARGV) . "\n" if @ARGV;
if ($help) {
    print_help();
    exit 0;
}

my $mode = detect_mode();
validate_mode_options($mode, \%opt_seen);
warn_incomplete_indexed_map();

if ($model ne 'mul' && $model ne 'add') {
    die "Invalid --model '$model'. Use 'mul' or 'add'.\n";
}
if ($model eq 'add' && !$step_set) {
    $step = 1e9;
}

my @collect_keys = @collect_data_keys ? @collect_data_keys : sort keys %default_param_map;
my $tuning_basename = basename($param_tuning_file);
my @required_files_to_check = map { basename($_) } build_files_to_copy();

sub run_build_and_execute {
    prepare_output_dirs($output_dir, 1);
    process_output_directories($output_dir, \@required_files_to_check, \@run_commands, undef);
}

if ($mode eq 'collect') {
    my ($data_header, $data_rows, $stats) = collect_merged_data(
        $output_dir,
        $data_file,
        \@collect_file_keywords,
        \@collect_keys
    );
    print "Collect flow complete. Output: $data_file\n";
    exit 0;
}

if ($mode eq 'no-tune') {
    run_build_and_execute();
    collect_merged_data(
        $output_dir,
        $data_file,
        \@collect_file_keywords,
        \@collect_keys
    );
    print "No-tune flow complete. Output: $data_file\n";
    exit 0;
}

# auto mode
require_auto_map_not_collapsed();
run_build_and_execute();
my ($data_header, $data_rows, $collect_stats) = collect_merged_data(
    $output_dir,
    $data_file,
    \@collect_file_keywords,
    \@collect_keys
);
require_non_empty_rows($data_rows, "output directory '$output_dir' with collect_file_keywords filter");
require_auto_map_columns_present($data_header);

my ($target_header, $target_rows) = read_csv($target_file);
require_target_join_column($target_header, $target_file);
my %target_by_key;
for my $row (@$target_rows) {
    my $key = $row->{$join_key} // '';
    $target_by_key{$key} = $row;
}
my $matched_key_count = count_join_key_matches($data_rows, \%target_by_key);
if ($matched_key_count == 0) {
    die "No matching '$join_key' between collected data and '$target_file'.\n"
      . "Run 'perl tune_params.pl --no-tune' first, then copy "
      . "'output/results/merged_data.csv' to 'target.csv' and edit target values.\n";
}

my $template_content = read_file($param_tuning_file);
my ($map_by_key, $param_list_ref, $param_allowed_ref) = build_param_context($data_header, $data_rows);

my @selected_params = ();
if ($params_cli ne '') {
    @selected_params = parse_param_filter($params_cli);
} elsif (@select_params) {
    @selected_params = @select_params;
}
if (@selected_params) {
    my %allow = map { $_ => 1 } @selected_params;
    my @filtered = grep { $allow{$_} } @$param_list_ref;
    my @missing = grep { !exists $param_allowed_ref->{$_} } @selected_params;
    warn "[WARN] selected params not found in mapping: " . join(', ', @missing) . "\n" if @missing;
    $param_list_ref = \@filtered;
    my %param_allowed = map { $_ => 1 } @filtered;
    $param_allowed_ref = \%param_allowed;
}
die "No parameters selected. Check --params or \\@select_params.\n" unless @$param_list_ref;

my $prev_params = (-e $out_file) ? read_prev_params($out_file, $param_list_ref) : {};
my $round = 0;
while (1) {
    my @output_cols = grep { $_ ne 'File_Path' && $_ ne 'File_Name' } @$data_header;
    my $iter_limit = 1;

    my ($results, $all_ok) = compute_params(
        $data_rows,
        \@output_cols,
        $iter_limit,
        $prev_params,
        \%target_by_key,
        $map_by_key,
        $param_list_ref,
        $param_allowed_ref
    );
    write_reports($results, \@output_cols, $param_list_ref, \%target_by_key);

    if ($all_ok) {
        print "Converged at round $round.\n";
        last;
    }

    if ($round >= $max_rounds) {
        warn "[WARN] reached max_rounds without convergence\n";
        last;
    }

    write_templates($results, $template_content, 1, $tuning_basename);

    my @dirs_to_run = map { $_->{dir} } grep { $_->{param_changed} && $_->{dir} ne '' } @$results;
    if (!@dirs_to_run) {
        warn "[WARN] no directories need re-run; stopping to avoid infinite loop\n";
        last;
    }

    process_output_directories($output_dir, \@required_files_to_check, \@run_commands, \@dirs_to_run);
    ($data_header, $data_rows, $collect_stats) = collect_merged_data(
        $output_dir,
        $data_file,
        \@collect_file_keywords,
        \@collect_keys
    );
    require_non_empty_rows($data_rows, "output directory '$output_dir' after auto rerun");
    $prev_params = params_from_results($results, $param_list_ref);
    $round++;
}

print "Auto flow complete. Output: $out_file, Report: $report_file, Merged: $data_file\n";
