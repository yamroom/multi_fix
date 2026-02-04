#!/bin/bash

# 路径到你的文本文件
FILE="all.txt"
perl read_pm.pl > all.txt
# 使用awk命令读取和处理文件
awk '
BEGIN {
    # 初始化变量
    B = 0;
    C = 0;
    lkvth0 = 0;
    dvt0 = 0;
    A = 0;
}

{
    # 捕捉每行的变量和值
    if ($1 == "B") B = $3;
    if ($1 == "C") C = $3;
    if ($1 == "lkvth0") lkvth0 = $3;
    if ($1 == "dvt0") dvt0 = $3;
    if ($1 == "A") A = $3;
}

END {
    # 计算结果并打印
    print "vth =", B + C + vth_p;
    print "cgc =", cgc_p + C + lkvth0;
    print "ids =", ids_p + A + dvt0;
}
' $FILE
