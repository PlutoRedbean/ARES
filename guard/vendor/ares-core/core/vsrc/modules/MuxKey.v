/*****************
 * NR_KEY: 被按key查找的数据数
 * (2 ^ KEY_LEN) <= NR_KEY
 * 
 * 1. 需要使用者提供键值对的数量NR_KEY, 键值的位宽KEY_LEN以及数据的位宽DATA_LEN这三个参数, 
 *    并保证端口的信号宽度与提供的参数一致, 否则将会输出错误的结果
 * 2. 若列表中存在多个键值为key的数据, 则out的值是未定义的, 需要使用者来保证列表中的键值互不相同
 *
 * USAGE:
 * MuxKeyWithDefault #(4, 2, 1) i0 (out, key, default_out, {
 *   2'b00, in[0],
 *   2'b01, in[1],
 *   2'b10, in[2],
 *   2'b11, in[3]
 * });
 *
 **/

module MuxKey #(NR_KEY = 2, KEY_LEN = 1, DATA_LEN = 1) (
  output [DATA_LEN-1:0] out,
  input [KEY_LEN-1:0] key,
  input [NR_KEY*(KEY_LEN + DATA_LEN)-1:0] lut
);
  MuxKeyInternal #(NR_KEY, KEY_LEN, DATA_LEN, 0) i0 (out, key, {DATA_LEN{1'b0}}, lut);
endmodule
