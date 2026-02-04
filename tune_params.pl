#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);

#
# 使用說明 (繁體中文)
# 1) 一般全流程：
#    perl tune_params.pl --auto --full
# 2) 不調參（只建立輸出 + 執行指令 + 收集資料）：
#    perl tune_params.pl --no-tune --full
# 3) 參數對應：
#    - 使用 %default_param_map 決定「輸出欄位 -> 參數」
#    - 沒列在 %default_param_map 的欄位不會被調整
# 4) 收集檔案/數據關鍵字：
#    - @collect_file_keywords 決定要收集的檔名（關鍵字）
#    - @collect_data_keys 決定要收集的數據 key（空則用 %default_param_map 的 key）
# 4) 指定只調哪些參數：
#    - USER CONFIG 中 @select_params
#    - 或 CLI：--params cgc_p,ids_p
#
# =========================
# 使用者設定 (可改)
# =========================
# 輸入
my $target_file = 'target.csv';
my $param_tuning_file = 'netlist.sh'; # 參數要被替換的檔案
my $output_dir = 'output';

# 輸出資料夾修改規則（矩陣 / 笛卡爾拆分）
# 注意：這裡的 file 也會被複製到每個 output 子資料夾
my @modifications = (
    { file => 'read_pm.pl', keyword => 'C = 3', new_lines => ['C=3', 'C=2', 'C=1'], lines => [9] },
    { file => 'read_pm.pl', keyword => 'lkvth0 = 5', new_lines => ['lkvth0 = 2', 'lkvth0 = 0'], lines => [17] }
);

# 每個 output 子資料夾要執行的指令
# 注意：若 param_tuning_file 改名，這裡也要同步更新
my @run_commands = (
    "sh netlist.sh > all.txt.tmp",
    "mv all.txt.tmp all.txt"
);

# 收集檔案關鍵字（檔名包含即可）
# 若留空，會收集所有檔案
my @collect_file_keywords = ('all.txt');

# 收集數據關鍵字（key 名稱）
# 若留空，會使用 %default_param_map 的 key
my @collect_data_keys = ();

# 內建對應（輸出欄位 -> 參數）
# 可在這裡自訂，例如 cgc => cgc_p
my %default_param_map = (
    cgc => 'cgc_p',
    vth => 'vth_p',
    ids => 'ids_p',
);

# 輸出
my $out_file = 'output/results/tuned_params.csv';
my $report_file = 'output/results/tuning_report.csv';
my $data_file = 'output/results/merged_data.csv';

# 調參行為
my $join_key = 'File_Path';
my $tol = 0.05;
my $step = 1.02;
my $max_iter = 50;
my $min_param = 1e-6;
my $max_param = 1e6;
my $model = 'add';
my $max_rounds = 10;
my @select_params = ();

# 流程預設
my $auto = 0;
my $full = 0;
my $collect = 0;
my $emit_merged = 0;
my $no_clean = 0;
my $no_tune = 0;

# =========================
# 內部參數 (不建議改)
# =========================
my $step_set = 0;
my $params_cli = '';

# =========================
# CLI 解析
# =========================
GetOptions(
    'data=s'        => \$data_file,
    'target=s'      => \$target_file,
    'params=s'      => \$params_cli,
    'join-key=s'    => \$join_key,
    'tol=f'         => \$tol,
    'step=f'        => sub { $step = $_[1]; $step_set = 1; },
    'max-iter=i'    => \$max_iter,
    'min-param=f'   => \$min_param,
    'max-param=f'   => \$max_param,
    'out=s'         => \$out_file,
    'report=s'      => \$report_file,
    'model=s'       => \$model,
    'tuning-file=s' => \$param_tuning_file,
    'template=s'    => \$param_tuning_file,
    'auto!'         => \$auto,
    'full!'         => \$full,
    'no-tune!'      => \$no_tune,
    'max-rounds=i'  => \$max_rounds,
    'output-dir=s'  => \$output_dir,
    'collect!'      => \$collect,
    'emit-merged!'  => \$emit_merged,
    'no-clean!'     => \$no_clean,
) or die "Usage: $0 --target target.csv [--auto --full] [--no-tune]\n";

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
# 依檔名關鍵字與數據 key 產生 merged_data
# =========================
sub collect_merged_data {
    my ($out_dir, $write_file, $out_csv, $file_keywords_ref, $data_keys_ref) = @_;
    my @file_keywords = $file_keywords_ref ? @$file_keywords_ref : ();
    my @data_keys = $data_keys_ref ? @$data_keys_ref : ();
    my %data_allow = map { $_ => 1 } @data_keys;
    my $filter_data = @data_keys ? 1 : 0;
    my @dirs = list_output_dirs($out_dir);

    my @rows;
    my %all_keys;
    for my $path (@dirs) {
        opendir my $dh, $path or next;
        my @files = grep { -f "$path/$_" } readdir $dh;
        closedir $dh;

        for my $fname (@files) {
            if (@file_keywords) {
                my $matched = 0;
                for my $kw (@file_keywords) {
                    next if !defined $kw || $kw eq '';
                    if (index($fname, $kw) >= 0) {
                        $matched = 1;
                        last;
                    }
                }
                next unless $matched;
            }

            my $file = "$path/$fname";
            open my $fh, '<', $file or next;
            my %row;
            $row{'File_Path'} = abs_path($file) // $file;
            $row{'File_Name'} = $fname;
            while (my $line = <$fh>) {
                chomp $line;
                if ($line =~ /^\s*(\w+)\s*[:=]\s*([-\w.]+)\s*$/) {
                    my ($key, $val) = ($1, $2);
                    next if $filter_data && !$data_allow{$key};
                    $row{$key} = $val;
                    $all_keys{$key} = 1;
                }
            }
            close $fh;
            push @rows, \%row;
        }
    }

    my @header = ('File_Path', 'File_Name', sort keys %all_keys);

    if ($write_file) {
        ensure_parent_dir($out_csv);
        open my $out_fh, '>', $out_csv or die "Cannot write $out_csv: $!";
        print $out_fh join(',', map { csv_escape($_) } @header), "\n";
        for my $row (@rows) {
            my @vals = map { $row->{$_} // '' } @header;
            print $out_fh join(',', map { csv_escape($_) } @vals), "\n";
        }
        close $out_fh;
    }

    return (\@header, \@rows);
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
                    warn "[WARN] non-numeric data/target for key '$key' column '$col'\n" if $iter == 0;
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
if ($model ne 'mul' && $model ne 'add') {
    die "Invalid --model '$model'. Use 'mul' or 'add'.\n";
}
if ($model eq 'add' && !$step_set) {
    $step = 1e9;
}

my @collect_keys = @collect_data_keys ? @collect_data_keys : sort keys %default_param_map;
$emit_merged = 1 if $collect;
my $tuning_basename = basename($param_tuning_file);
my @required_files_to_check = map { basename($_) } build_files_to_copy();

if ($no_tune) {
    $emit_merged = 1;
    $full = 1;
}

if ($full) {
    prepare_output_dirs($output_dir, $no_clean ? 0 : 1);
    process_output_directories($output_dir, \@required_files_to_check, \@run_commands, undef);
}

my $round = 0;
my ($data_header, $data_rows);
if ($auto || $collect || $no_tune) {
    ($data_header, $data_rows) = collect_merged_data(
        $output_dir,
        $emit_merged,
        $data_file,
        \@collect_file_keywords,
        \@collect_keys
    );
} else {
    ($data_header, $data_rows) = read_csv($data_file);
}

if ($no_tune) {
    print "No-tune flow complete. Output: $data_file\n";
    exit 0;
}

my ($target_header, $target_rows) = read_csv($target_file);
my %target_by_key;
for my $row (@$target_rows) {
    my $key = $row->{$join_key} // '';
    $target_by_key{$key} = $row;
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

my $prev_params = ($auto && -e $out_file) ? read_prev_params($out_file, $param_list_ref) : {};

while (1) {
    my @output_cols = grep { $_ ne 'File_Path' && $_ ne 'File_Name' } @$data_header;
    my $iter_limit = $auto ? 1 : $max_iter;

    my ($results, $all_ok) = compute_params($data_rows, \@output_cols, $iter_limit, $prev_params, \%target_by_key, $map_by_key, $param_list_ref, $param_allowed_ref);
    write_reports($results, \@output_cols, $param_list_ref, \%target_by_key);

    if (!$auto) {
        write_templates($results, $template_content, 0, $tuning_basename);
        last;
    }

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

    ($data_header, $data_rows) = collect_merged_data(
        $output_dir,
        $emit_merged,
        $data_file,
        \@collect_file_keywords,
        \@collect_keys
    );
    $prev_params = params_from_results($results, $param_list_ref);

    $round++;
}

print "Tuning complete. Output: $out_file, Report: $report_file\n";
