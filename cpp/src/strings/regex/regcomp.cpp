/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <strings/regex/regcomp.h>

#include <cudf/strings/detail/utf8.hpp>
#include <cudf/utilities/error.hpp>

#include <algorithm>
#include <array>
#include <cctype>
#include <numeric>
#include <stack>
#include <string>
#include <tuple>
#include <vector>

namespace cudf {
namespace strings {
namespace detail {
namespace {
// Bitmask of all operators
#define OPERATOR_MASK 0200
enum OperatorType {
  START        = 0200,  // Start, used for marker on stack
  LBRA_NC      = 0203,  // non-capturing group
  CAT          = 0205,  // Concatentation, implicit operator
  STAR         = 0206,  // Closure, *
  STAR_LAZY    = 0207,
  PLUS         = 0210,  // a+ == aa*
  PLUS_LAZY    = 0211,
  QUEST        = 0212,  // a? == a|nothing, i.e. 0 or 1 a's
  QUEST_LAZY   = 0213,
  COUNTED      = 0214,  // counted repeat a{2} a{3,5}
  COUNTED_LAZY = 0215,
  NOP          = 0302,  // No operation, internal use only
};
#define ITEM_MASK 0300

static reclass ccls_w(CCLASS_W);   // \w
static reclass ccls_s(CCLASS_S);   // \s
static reclass ccls_d(CCLASS_D);   // \d
static reclass ccls_W(NCCLASS_W);  // \W
static reclass ccls_S(NCCLASS_S);  // \S
static reclass ccls_D(NCCLASS_D);  // \D

// Tables for analyzing quantifiers
const std::array<int, 6> valid_preceding_inst_types{{CHAR, CCLASS, NCCLASS, ANY, ANYNL, RBRA}};
const std::array<char, 5> quantifiers{{'*', '?', '+', '{', '|'}};
// Valid regex characters that can be escaped and used as literals
const std::array<char, 33> escapable_chars{
  {'.', '-', '+',  '*', '\\', '?', '^', '$', '|', '{', '}', '(', ')', '[', ']', '<', '>',
   '"', '~', '\'', '`', '_',  '@', '=', ';', ':', '!', '#', '%', '&', ',', '/', ' '}};

/**
 * @brief Converts UTF-8 string into fixed-width 32-bit character vector.
 *
 * No character conversion occurs.
 * Each UTF-8 character is promoted into a 32-bit value.
 * The last entry in the returned vector will be a 0 value.
 * The fixed-width vector makes it easier to compile and faster to execute.
 *
 * @param pattern Regular expression encoded with UTF-8.
 * @return Fixed-width 32-bit character vector.
 */
std::vector<char32_t> string_to_char32_vector(std::string_view pattern)
{
  size_type size  = static_cast<size_type>(pattern.size());
  size_type count = std::count_if(pattern.cbegin(), pattern.cend(), [](char ch) {
    return is_begin_utf8_char(static_cast<uint8_t>(ch));
  });
  std::vector<char32_t> result(count + 1);
  char32_t* output_ptr  = result.data();
  const char* input_ptr = pattern.data();
  for (size_type idx = 0; idx < size; ++idx) {
    char_utf8 output_character = 0;
    size_type ch_width         = to_char_utf8(input_ptr, output_character);
    input_ptr += ch_width;
    idx += ch_width - 1;
    *output_ptr++ = output_character;
  }
  result[count] = 0;  // last entry set to 0
  return result;
}

}  // namespace

int32_t reprog::add_inst(int32_t t)
{
  reinst inst;
  inst.type        = t;
  inst.u2.left_id  = 0;
  inst.u1.right_id = 0;
  return add_inst(inst);
}

int32_t reprog::add_inst(reinst inst)
{
  _insts.push_back(inst);
  return static_cast<int>(_insts.size() - 1);
}

int32_t reprog::add_class(reclass cls)
{
  _classes.push_back(cls);
  return static_cast<int>(_classes.size() - 1);
}

reinst& reprog::inst_at(int32_t id) { return _insts[id]; }

reclass& reprog::class_at(int32_t id) { return _classes[id]; }

void reprog::set_start_inst(int32_t id) { _startinst_id = id; }

int32_t reprog::get_start_inst() const { return _startinst_id; }

int32_t reprog::insts_count() const { return static_cast<int>(_insts.size()); }

int32_t reprog::classes_count() const { return static_cast<int>(_classes.size()); }

void reprog::set_groups_count(int32_t groups) { _num_capturing_groups = groups; }

int32_t reprog::groups_count() const { return _num_capturing_groups; }

const reinst* reprog::insts_data() const { return _insts.data(); }

const int32_t* reprog::starts_data() const { return _startinst_ids.data(); }

int32_t reprog::starts_count() const { return static_cast<int>(_startinst_ids.size()); }

/**
 * @brief Converts pattern into regex classes
 */
class regex_parser {
 public:
  /**
   * @brief Single parsed pattern element.
   */
  struct Item {
    int32_t type;
    union {
      char32_t chr;
      int32_t cclass_id;
      struct {
        int16_t n;
        int16_t m;
      } count;
    } d;
    Item(int32_t type, char32_t chr) : type{type}, d{chr} {}
    Item(int32_t type, int32_t id) : type{type}, d{.cclass_id{id}} {}
    Item(int32_t type, int16_t n, int16_t m) : type{type}, d{.count{n, m}} {}
  };

 private:
  reprog& _prog;
  char32_t const* const _pattern_begin;
  char32_t const* _expr_ptr;
  bool _lex_done{false};

  int32_t _id_cclass_w{-1};  // alphanumeric [a-zA-Z0-9_]
  int32_t _id_cclass_W{-1};  // not alphanumeric plus '\n'
  int32_t _id_cclass_s{-1};  // whitespace including '\t', '\n', '\r'
  int32_t _id_cclass_d{-1};  // digits [0-9]
  int32_t _id_cclass_D{-1};  // not digits

  char32_t _chr{};       // last lex'd char
  int32_t _cclass_id{};  // last lex'd class
  int16_t _min_count{};  // data for counted operators
  int16_t _max_count{};

  std::vector<Item> _items;
  bool _has_counted{false};

  /**
   * @brief Returns the next character in the expression
   *
   * Handles quoted (escaped) special characters and detecting the end of the expression.
   *
   * @return is-backslash-escape and character
   */
  std::pair<bool, char32_t> next_char()
  {
    if (_lex_done) { return {true, 0}; }

    auto c = *_expr_ptr++;
    if (c == '\\') {
      c = *_expr_ptr++;
      return {true, c};
    }

    if (c == 0) { _lex_done = true; }

    return {false, c};
  }

  int32_t build_cclass()
  {
    int32_t type = CCLASS;
    std::vector<char32_t> cls;
    int32_t builtins = 0;

    auto [is_quoted, chr] = next_char();
    // check for negation
    if (!is_quoted && chr == '^') {
      type                     = NCCLASS;
      std::tie(is_quoted, chr) = next_char();
      // negated classes also do not match '\n'
      cls.push_back('\n');
      cls.push_back('\n');
    }

    // parse class into a set of spans
    auto count_char = 0;
    while (true) {
      count_char++;
      if (chr == 0) {
        // malformed '[]'
        return 0;
      }
      if (is_quoted) {
        switch (chr) {
          case 'n': chr = '\n'; break;
          case 'r': chr = '\r'; break;
          case 't': chr = '\t'; break;
          case 'a': chr = 0x07; break;
          case 'b': chr = 0x08; break;
          case 'f': chr = 0x0C; break;
          case 'w':
            builtins |= ccls_w.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
          case 's':
            builtins |= ccls_s.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
          case 'd':
            builtins |= ccls_d.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
          case 'W':
            builtins |= ccls_W.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
          case 'S':
            builtins |= ccls_S.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
          case 'D':
            builtins |= ccls_D.builtins;
            std::tie(is_quoted, chr) = next_char();
            continue;
        }
      }
      if (!is_quoted && chr == ']' && count_char > 1) break;
      if (!is_quoted && chr == '-') {
        if (cls.empty()) {
          // malformed '[]': TODO assert or exception?
          return 0;
        }
        std::tie(is_quoted, chr) = next_char();
        if ((!is_quoted && chr == ']') || chr == 0) {
          // malformed '[]': TODO assert or exception?
          return 0;
        }
        cls.back() = chr;
      } else {
        cls.push_back(chr);
        cls.push_back(chr);
      }
      std::tie(is_quoted, chr) = next_char();
    }

    /* sort on span start */
    for (std::size_t p = 0; p < cls.size(); p += 2)
      for (std::size_t np = p + 2; np < cls.size(); np += 2)
        if (cls[np] < cls[p]) {
          auto c      = cls[np];
          cls[np]     = cls[p];
          cls[p]      = c;
          c           = cls[np + 1];
          cls[np + 1] = cls[p + 1];
          cls[p + 1]  = c;
        }

    /* merge spans */
    reclass yycls{builtins};
    if (cls.size() >= 2) {
      int np        = 0;
      std::size_t p = 0;
      yycls.literals += cls[p++];
      yycls.literals += cls[p++];
      for (; p < cls.size(); p += 2) {
        /* overlapping or adjacent ranges? */
        if (cls[p] <= yycls.literals[np + 1] + 1) {
          if (cls[p + 1] >= yycls.literals[np + 1])
            yycls.literals.replace(np + 1, 1, 1, cls[p + 1]); /* coalesce */
        } else {
          np += 2;
          yycls.literals += cls[p];
          yycls.literals += cls[p + 1];
        }
      }
    }
    _cclass_id = _prog.add_class(yycls);
    return type;
  }

  int32_t lex(int32_t dot_type)
  {
    _chr = 0;

    auto [is_quoted, chr] = next_char();
    if (is_quoted) {
      // treating all quoted numbers as Octal, since we are not supporting backreferences
      if (chr >= '0' && chr <= '7') {
        chr         = chr - '0';
        auto c      = *_expr_ptr;
        auto digits = 1;
        while (c >= '0' && c <= '7' && digits < 3) {
          chr = (chr << 3) | (c - '0');
          c   = *(++_expr_ptr);
          ++digits;
        }
        _chr = chr;
        return CHAR;
      } else {
        switch (chr) {
          case 't': chr = '\t'; break;
          case 'n': chr = '\n'; break;
          case 'r': chr = '\r'; break;
          case 'a': chr = 0x07; break;
          case 'f': chr = 0x0C; break;
          case '0': chr = 0; break;
          case 'x': {
            char32_t a = *_expr_ptr++;
            char32_t b = *_expr_ptr++;
            chr        = 0;
            if (a >= '0' && a <= '9')
              chr += (a - '0') << 4;
            else if (a >= 'a' && a <= 'f')
              chr += (a - 'a' + 10) << 4;
            else if (a >= 'A' && a <= 'F')
              chr += (a - 'A' + 10) << 4;
            if (b >= '0' && b <= '9')
              chr += b - '0';
            else if (b >= 'a' && b <= 'f')
              chr += b - 'a' + 10;
            else if (b >= 'A' && b <= 'F')
              chr += b - 'A' + 10;
            break;
          }
          case 'w': {
            if (_id_cclass_w < 0) { _id_cclass_w = _prog.add_class(ccls_w); }
            _cclass_id = _id_cclass_w;
            return CCLASS;
          }
          case 'W': {
            if (_id_cclass_W < 0) {
              reclass cls = ccls_w;
              cls.literals += '\n';
              cls.literals += '\n';
              _id_cclass_W = _prog.add_class(cls);
            }
            _cclass_id = _id_cclass_W;
            return NCCLASS;
          }
          case 's': {
            if (_id_cclass_s < 0) { _id_cclass_s = _prog.add_class(ccls_s); }
            _cclass_id = _id_cclass_s;
            return CCLASS;
          }
          case 'S': {
            if (_id_cclass_s < 0) { _id_cclass_s = _prog.add_class(ccls_s); }
            _cclass_id = _id_cclass_s;
            return NCCLASS;
          }
          case 'd': {
            if (_id_cclass_d < 0) { _id_cclass_d = _prog.add_class(ccls_d); }
            _cclass_id = _id_cclass_d;
            return CCLASS;
          }
          case 'D': {
            if (_id_cclass_D < 0) {
              reclass cls = ccls_d;
              cls.literals += '\n';
              cls.literals += '\n';
              _id_cclass_D = _prog.add_class(cls);
            }
            _cclass_id = _id_cclass_D;
            return NCCLASS;
          }
          case 'b': return BOW;
          case 'B': return NBOW;
          case 'A': return BOL;
          case 'Z': return EOL;
          default: {
            // let valid escapable chars fall through as literal CHAR
            if (chr && (std::find(escapable_chars.begin(),
                                  escapable_chars.end(),
                                  static_cast<char>(chr)) != escapable_chars.end())) {
              break;
            }
            // anything else is a bad escape so throw an error
            CUDF_FAIL("invalid regex pattern: bad escape character at position " +
                      std::to_string(_expr_ptr - _pattern_begin - 1));
          }
        }  // end-switch
        _chr = chr;
        return CHAR;
      }
    }

    // handle regex characters
    switch (chr) {
      case 0: return END;
      case '(':
        if (*_expr_ptr == '?' && *(_expr_ptr + 1) == ':')  // non-capturing group
        {
          _expr_ptr += 2;
          return LBRA_NC;
        }
        return LBRA;
      case ')': return RBRA;
      case '^': {
        _chr = chr;
        return BOL;
      }
      case '$': {
        _chr = chr;
        return EOL;
      }
      case '[': return build_cclass();
      case '.': return dot_type;
    }

    if (std::find(quantifiers.begin(), quantifiers.end(), static_cast<char>(chr)) ==
        quantifiers.end()) {
      _chr = chr;
      return CHAR;
    }

    // The quantifiers require at least one "real" previous item.
    // We are throwing an error in these two if-checks for invalid quantifiers.
    // Another option is to just return CHAR silently here which effectively
    // treats the chr character as a literal instead as a quantifier.
    // This could lead to confusion where sometimes unescaped quantifier characters
    // are treated as regex expressions and sometimes they are not.
    if (_items.empty()) { CUDF_FAIL("invalid regex pattern: nothing to repeat at position 0"); }

    if (std::find(valid_preceding_inst_types.begin(),
                  valid_preceding_inst_types.end(),
                  _items.back().type) == valid_preceding_inst_types.end()) {
      CUDF_FAIL("invalid regex pattern: nothing to repeat at position " +
                std::to_string(_expr_ptr - _pattern_begin - 1));
    }

    // handle quantifiers
    switch (chr) {
      case '*':
        if (*_expr_ptr == '?') {
          _expr_ptr++;
          return STAR_LAZY;
        }
        return STAR;
      case '?':
        if (*_expr_ptr == '?') {
          _expr_ptr++;
          return QUEST_LAZY;
        }
        return QUEST;
      case '+':
        if (*_expr_ptr == '?') {
          _expr_ptr++;
          return PLUS_LAZY;
        }
        return PLUS;
      case '{':  // counted repetition: {n,m}
      {
        if (!std::isdigit(*_expr_ptr)) { break; }

        // transform char32 to char until null, delimiter, non-digit or end is reached;
        // returns the number of chars read/transformed
        auto transform_until = [](char32_t const* input,
                                  char32_t const* end,
                                  char* output,
                                  std::string_view const delimiters) -> int32_t {
          int32_t count = 0;
          while (*input != 0 && input < end) {
            auto const ch = static_cast<char>(*input++);
            // if ch not a digit or ch is a delimiter, we are done
            if (!std::isdigit(ch) || delimiters.find(ch) != delimiters.npos) { break; }
            output[count] = ch;
            ++count;
          }
          output[count] = 0;  // null-terminate (for the atoi call)
          return count;
        };

        constexpr auto max_read               = 4;    // 3 digits plus the delimiter
        constexpr auto max_value              = 999;  // support only 3 digits
        std::array<char, max_read + 1> buffer = {0};  //(max_read + 1);

        // get left-side (n) value => min_count
        auto bytes_read = transform_until(_expr_ptr, _expr_ptr + max_read, buffer.data(), "},");
        if (_expr_ptr[bytes_read] != '}' && _expr_ptr[bytes_read] != ',') {
          break;  // re-interpret as CHAR
        }
        auto count = std::atoi(buffer.data());
        CUDF_EXPECTS(
          count <= max_value,
          "unsupported repeat value at " + std::to_string(_expr_ptr - _pattern_begin - 1));
        _min_count = static_cast<int16_t>(count);

        auto const expr_ptr_save = _expr_ptr;  // save in case ending '}' is not found
        _expr_ptr += bytes_read;

        // get optional right-side (m) value => max_count
        _max_count = _min_count;
        if (*_expr_ptr++ == ',') {
          bytes_read = transform_until(_expr_ptr, _expr_ptr + max_read, buffer.data(), "}");
          if (_expr_ptr[bytes_read] != '}') {
            _expr_ptr = expr_ptr_save;  // abort, rollback and
            break;                      // re-interpret as CHAR
          }

          count = std::atoi(buffer.data());
          CUDF_EXPECTS(
            count <= max_value,
            "unsupported repeat value at " + std::to_string(_expr_ptr - _pattern_begin - 1));

          // {n,m} and {n,} are both valid
          _max_count = buffer[0] == 0 ? -1 : static_cast<int16_t>(count);
          _expr_ptr += bytes_read + 1;
        }

        // {n,m}? pattern is lazy counted quantifier
        if (*_expr_ptr == '?') {
          _expr_ptr++;
          return COUNTED_LAZY;
        }
        // otherwise, fixed counted quantifier
        return COUNTED;
      }
      case '|': return OR;
    }
    _chr = chr;
    return CHAR;
  }

  std::vector<regex_parser::Item> expand_counted_items() const
  {
    std::vector<regex_parser::Item> const& in = _items;
    std::vector<regex_parser::Item> out;
    std::stack<int> lbra_stack;
    auto repeat_start_index = -1;

    for (std::size_t index = 0; index < in.size(); index++) {
      auto const item = in[index];

      if (item.type != COUNTED && item.type != COUNTED_LAZY) {
        out.push_back(item);
        if (item.type == LBRA || item.type == LBRA_NC) {
          lbra_stack.push(index);
          repeat_start_index = -1;
        } else if (item.type == RBRA) {
          repeat_start_index = lbra_stack.top();
          lbra_stack.pop();
        } else if ((item.type & ITEM_MASK) != OPERATOR_MASK) {
          repeat_start_index = index;
        }
      } else {
        // item is of type COUNTED or COUNTED_LAZY
        // here we repeat the previous item(s) based on the count range in item

        CUDF_EXPECTS(repeat_start_index >= 0, "regex: invalid counted quantifier location");

        // range of affected item(s) to repeat
        auto const begin = in.begin() + repeat_start_index;
        auto const end   = in.begin() + index;
        // count range values
        auto const n = item.d.count.n;  // minimum count
        auto const m = item.d.count.m;  // maximum count

        assert(n >= 0 && "invalid repeat count value n");
        // zero-repeat edge-case: need to erase the previous items
        if (n == 0) { out.erase(out.end() - (index - repeat_start_index), out.end()); }

        // minimum repeats (n)
        for (int j = 1; j < n; j++) {
          out.insert(out.end(), begin, end);
        }

        // optional maximum repeats (m)
        if (m >= 0) {
          for (int j = n; j < m; j++) {
            out.push_back(regex_parser::Item{LBRA_NC, 0});
            out.insert(out.end(), begin, end);
          }
          for (int j = n; j < m; j++) {
            out.push_back(regex_parser::Item{RBRA, 0});
            out.push_back(regex_parser::Item{item.type == COUNTED ? QUEST : QUEST_LAZY, 0});
          }
        } else {
          // infinite repeats
          if (n > 0) {  // append '+' after last repetition
            out.push_back(regex_parser::Item{item.type == COUNTED ? PLUS : PLUS_LAZY, 0});
          } else {  // copy it once then append '*'
            out.insert(out.end(), begin, end);
            out.push_back(regex_parser::Item{item.type == COUNTED ? STAR : STAR_LAZY, 0});
          }
        }
      }
    }
    return out;
  }

 public:
  regex_parser(const char32_t* pattern, int32_t dot_type, reprog& prog)
    : _prog(prog), _pattern_begin(pattern), _expr_ptr(pattern)
  {
    int32_t type = 0;
    while ((type = lex(dot_type)) != END) {
      auto const item = [type, chr = _chr, cid = _cclass_id, n = _min_count, m = _max_count] {
        if (type == CCLASS || type == NCCLASS) return Item{type, cid};
        if (type == COUNTED || type == COUNTED_LAZY) return Item{type, n, m};
        return Item{type, chr};
      }();
      _items.push_back(item);
      if (type == COUNTED || type == COUNTED_LAZY) _has_counted = true;
    }
  }

  std::vector<regex_parser::Item> get_items() const
  {
    return _has_counted ? expand_counted_items() : _items;
  }
};

/**
 * @brief The compiler converts class list into instructions.
 */
class regex_compiler {
  struct and_node {
    int id_first;
    int id_last;
  };

  struct re_operator {
    int t;
    int subid;
  };

  reprog& _prog;
  std::stack<and_node> _and_stack;
  std::stack<re_operator> _operator_stack;
  bool _last_was_and;
  int _bracket_count;
  regex_flags _flags;

  inline void push_and(int first, int last) { _and_stack.push({first, last}); }

  inline and_node pop_and()
  {
    if (_and_stack.empty()) {
      auto const inst_id = _prog.add_inst(NOP);
      push_and(inst_id, inst_id);
    }
    auto const node = _and_stack.top();
    _and_stack.pop();
    return node;
  }

  inline void push_operator(int token, int subid = 0)
  {
    _operator_stack.push(re_operator{token, subid});
  }

  inline re_operator const pop_operator()
  {
    auto const op = _operator_stack.top();
    _operator_stack.pop();
    return op;
  }

  void eval_until(int min_token)
  {
    while (min_token == RBRA || _operator_stack.top().t >= min_token) {
      auto const op = pop_operator();
      switch (op.t) {
        default:
          // unknown operator
          break;
        case LBRA:  // expects matching RBRA
        {
          auto const operand                        = pop_and();
          auto const id_inst2                       = _prog.add_inst(RBRA);
          _prog.inst_at(id_inst2).u1.subid          = op.subid;
          _prog.inst_at(operand.id_last).u2.next_id = id_inst2;
          auto const id_inst1                       = _prog.add_inst(LBRA);
          _prog.inst_at(id_inst1).u1.subid          = op.subid;
          _prog.inst_at(id_inst1).u2.next_id        = operand.id_first;
          push_and(id_inst1, id_inst2);
          return;
        }
        case OR: {
          auto const operand2                        = pop_and();
          auto const operand1                        = pop_and();
          auto const id_inst2                        = _prog.add_inst(NOP);
          _prog.inst_at(operand2.id_last).u2.next_id = id_inst2;
          _prog.inst_at(operand1.id_last).u2.next_id = id_inst2;
          auto const id_inst1                        = _prog.add_inst(OR);
          _prog.inst_at(id_inst1).u1.right_id        = operand1.id_first;
          _prog.inst_at(id_inst1).u2.left_id         = operand2.id_first;
          push_and(id_inst1, id_inst2);
          break;
        }
        case CAT: {
          auto const operand2                        = pop_and();
          auto const operand1                        = pop_and();
          _prog.inst_at(operand1.id_last).u2.next_id = operand2.id_first;
          push_and(operand1.id_first, operand2.id_last);
          break;
        }
        case STAR: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          _prog.inst_at(operand.id_last).u2.next_id = id_inst1;
          _prog.inst_at(id_inst1).u1.right_id       = operand.id_first;
          push_and(id_inst1, id_inst1);
          break;
        }
        case STAR_LAZY: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          auto const id_inst2                       = _prog.add_inst(NOP);
          _prog.inst_at(operand.id_last).u2.next_id = id_inst1;
          _prog.inst_at(id_inst1).u2.left_id        = operand.id_first;
          _prog.inst_at(id_inst1).u1.right_id       = id_inst2;
          push_and(id_inst1, id_inst2);
          break;
        }
        case PLUS: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          _prog.inst_at(operand.id_last).u2.next_id = id_inst1;
          _prog.inst_at(id_inst1).u1.right_id       = operand.id_first;
          push_and(operand.id_first, id_inst1);
          break;
        }
        case PLUS_LAZY: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          auto const id_inst2                       = _prog.add_inst(NOP);
          _prog.inst_at(operand.id_last).u2.next_id = id_inst1;
          _prog.inst_at(id_inst1).u2.left_id        = operand.id_first;
          _prog.inst_at(id_inst1).u1.right_id       = id_inst2;
          push_and(operand.id_first, id_inst2);
          break;
        }
        case QUEST: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          auto const id_inst2                       = _prog.add_inst(NOP);
          _prog.inst_at(id_inst1).u2.left_id        = id_inst2;
          _prog.inst_at(id_inst1).u1.right_id       = operand.id_first;
          _prog.inst_at(operand.id_last).u2.next_id = id_inst2;
          push_and(id_inst1, id_inst2);
          break;
        }
        case QUEST_LAZY: {
          auto const operand                        = pop_and();
          auto const id_inst1                       = _prog.add_inst(OR);
          auto const id_inst2                       = _prog.add_inst(NOP);
          _prog.inst_at(id_inst1).u2.left_id        = operand.id_first;
          _prog.inst_at(id_inst1).u1.right_id       = id_inst2;
          _prog.inst_at(operand.id_last).u2.next_id = id_inst2;
          push_and(id_inst1, id_inst2);
          break;
        }
      }
    }
  }

  void handle_operator(int token, int subid = 0)
  {
    if (token == RBRA && --_bracket_count < 0) {
      // unmatched right paren
      return;
    }
    if (token == LBRA) {
      _bracket_count++;
      if (_last_was_and) { handle_operator(CAT, subid); }
    } else {
      eval_until(token);
    }
    if (token != RBRA) { push_operator(token, subid); }

    static std::vector<int> tokens{STAR, STAR_LAZY, QUEST, QUEST_LAZY, PLUS, PLUS_LAZY, RBRA};
    _last_was_and =
      std::any_of(tokens.cbegin(), tokens.cend(), [token](auto t) { return t == token; });
  }

  void handle_operand(int token, int subid = 0, char32_t yy = 0, int class_id = 0)
  {
    if (_last_was_and) { handle_operator(CAT, subid); }  // catenate is implicit

    auto const inst_id = _prog.add_inst(token);
    if (token == CCLASS || token == NCCLASS) {
      _prog.inst_at(inst_id).u1.cls_id = class_id;
    } else if (token == CHAR) {
      _prog.inst_at(inst_id).u1.c = yy;
    } else if (token == BOL || token == EOL) {
      _prog.inst_at(inst_id).u1.c = is_multiline(_flags) ? yy : '\n';
    }
    push_and(inst_id, inst_id);
    _last_was_and = true;
  }

 public:
  regex_compiler(const char32_t* pattern, regex_flags const flags, reprog& prog)
    : _prog(prog), _last_was_and(false), _bracket_count(0), _flags(flags)
  {
    // Parse pattern into items
    auto const items = regex_parser(pattern, is_dotall(flags) ? ANYNL : ANY, _prog).get_items();

    int cur_subid{};
    int push_subid{};

    // Start with a low priority operator
    push_operator(START - 1);

    for (auto const item : items) {
      auto token = item.type;

      if (token == LBRA) {
        ++cur_subid;
        push_subid = cur_subid;
      } else if (token == LBRA_NC) {
        push_subid = 0;
        token      = LBRA;
      }

      if ((token & ITEM_MASK) == OPERATOR_MASK) {
        handle_operator(token, push_subid);
      } else {
        handle_operand(token, push_subid, item.d.chr, item.d.cclass_id);
      }
    }

    // Close with a low priority operator
    eval_until(START);
    // Force END
    handle_operand(END, push_subid);
    eval_until(START);

    CUDF_EXPECTS(_bracket_count == 0, "unmatched left parenthesis");

    _prog.set_start_inst(_and_stack.top().id_first);
    _prog.finalize();
    _prog.check_for_errors();
    _prog.set_groups_count(cur_subid);
  }
};

// Convert pattern into program
reprog reprog::create_from(std::string_view pattern, regex_flags const flags)
{
  reprog rtn;
  auto pattern32 = string_to_char32_vector(pattern);
  regex_compiler compiler(pattern32.data(), flags, rtn);
  // for debugging, it can be helpful to call rtn.print(flags) here to dump
  // out the instructions that have been created from the given pattern
  return rtn;
}

void reprog::finalize()
{
  collapse_nops();
  build_start_ids();
}

void reprog::collapse_nops()
{
  // treat non-capturing LBRAs/RBRAs as NOP
  std::transform(_insts.begin(), _insts.end(), _insts.begin(), [](auto inst) {
    if ((inst.type == LBRA || inst.type == RBRA) && (inst.u1.subid < 1)) { inst.type = NOP; }
    return inst;
  });

  // functor for finding the next valid op
  auto find_next_op = [insts = _insts](int id) {
    while (insts[id].type == NOP) {
      id = insts[id].u2.next_id;
    }
    return id;
  };

  // create new routes around NOP chains
  std::transform(_insts.begin(), _insts.end(), _insts.begin(), [find_next_op](auto inst) {
    if (inst.type != NOP) {
      inst.u2.next_id = find_next_op(inst.u2.next_id);
      if (inst.type == OR) { inst.u1.right_id = find_next_op(inst.u1.right_id); }
    }
    return inst;
  });

  // find starting op
  _startinst_id = find_next_op(_startinst_id);

  // build a map of op ids
  // these are used to fix up the ids after the NOPs are removed
  std::vector<int> id_map(insts_count());
  std::transform_exclusive_scan(
    _insts.begin(), _insts.end(), id_map.begin(), 0, std::plus<int>{}, [](auto inst) {
      return static_cast<int>(inst.type != NOP);
    });

  // remove the NOP instructions
  auto end = std::remove_if(_insts.begin(), _insts.end(), [](auto i) { return i.type == NOP; });
  _insts.resize(std::distance(_insts.begin(), end));

  // fix up the ids on the remaining instructions using the id_map
  std::transform(_insts.begin(), _insts.end(), _insts.begin(), [id_map](auto inst) {
    inst.u2.next_id = id_map[inst.u2.next_id];
    if (inst.type == OR) { inst.u1.right_id = id_map[inst.u1.right_id]; }
    return inst;
  });

  // fix up the start instruction id too
  _startinst_id = id_map[_startinst_id];
}

// expand leading ORs to multiple startinst_ids
void reprog::build_start_ids()
{
  _startinst_ids.clear();
  std::stack<int> ids;
  ids.push(_startinst_id);
  while (!ids.empty()) {
    int id = ids.top();
    ids.pop();
    const reinst& inst = _insts[id];
    if (inst.type == OR) {
      if (inst.u2.left_id != id)  // prevents infinite while-loop here
        ids.push(inst.u2.left_id);
      if (inst.u1.right_id != id)  // prevents infinite while-loop here
        ids.push(inst.u1.right_id);
    } else {
      _startinst_ids.push_back(id);
    }
  }
  _startinst_ids.push_back(-1);  // terminator mark
}

/**
 * @brief Check a specific instruction for errors.
 *
 * Currently this is checking for an infinite-loop condition as documented in this issue:
 * https://github.com/rapidsai/cudf/issues/10006
 *
 * Example instructions list created from pattern `(A?)+`
 * ```
 *   0:    CHAR c='A', next=2
 *   1:      OR right=0, left=2, next=2
 *   2:    RBRA id=1, next=4
 *   3:    LBRA id=1, next=1
 *   4:      OR right=3, left=5, next=5
 *   5:     END
 * ```
 *
 * Following the example above, the instruction at `id==1` (OR)
 * is being checked. If the instruction path returns to `id==1`
 * without including the `0==CHAR` or `5==END` as in this example,
 * then this would cause the runtime to go into an infinite-loop.
 *
 * It appears this example pattern is not valid. But Python interprets
 * its behavior similarly to pattern `(A*)`. Handling this in the same
 * way does not look feasible with the current implementation.
 *
 * @throw cudf::logic_error if instruction logic error is found
 *
 * @param id Instruction to check if repeated.
 * @param next_id Next instruction to process.
 */
void reprog::check_for_errors(int32_t id, int32_t next_id)
{
  auto inst = inst_at(next_id);
  while (inst.type == LBRA || inst.type == RBRA) {
    next_id = inst.u2.next_id;
    inst    = inst_at(next_id);
  }
  if (inst.type == OR) {
    CUDF_EXPECTS(next_id != id, "Unsupported regex pattern");
    check_for_errors(id, inst.u2.left_id);
    check_for_errors(id, inst.u1.right_id);
  }
}

/**
 * @brief Check regex instruction set for any errors.
 *
 * Currently, this checks for OR instructions that eventually point back to themselves with only
 * intervening capture group instructions between causing an infinite-loop during runtime
 * evaluation.
 */
void reprog::check_for_errors()
{
  for (auto id = 0; id < insts_count(); ++id) {
    auto const inst = inst_at(id);
    if (inst.type == OR) {
      check_for_errors(id, inst.u2.left_id);
      check_for_errors(id, inst.u1.right_id);
    }
  }
}

#ifndef NDEBUG
void reprog::print(regex_flags const flags)
{
  printf("Flags = 0x%08x\n", static_cast<uint32_t>(flags));
  printf("Instructions:\n");
  for (std::size_t i = 0; i < _insts.size(); i++) {
    const reinst& inst = _insts[i];
    printf("%3zu: ", i);
    switch (inst.type) {
      default: printf("Unknown instruction: %d, next=%d", inst.type, inst.u2.next_id); break;
      case CHAR:
        if (inst.u1.c <= 32 || inst.u1.c >= 127) {
          printf("   CHAR c='0x%02x', next=%d", static_cast<unsigned>(inst.u1.c), inst.u2.next_id);
        } else {
          printf("   CHAR c='%c', next=%d", inst.u1.c, inst.u2.next_id);
        }
        break;
      case RBRA: printf("   RBRA id=%d, next=%d", inst.u1.subid, inst.u2.next_id); break;
      case LBRA: printf("   LBRA id=%d, next=%d", inst.u1.subid, inst.u2.next_id); break;
      case OR:
        printf(
          "     OR right=%d, left=%d, next=%d", inst.u1.right_id, inst.u2.left_id, inst.u2.next_id);
        break;
      case STAR: printf("   STAR next=%d", inst.u2.next_id); break;
      case PLUS: printf("   PLUS next=%d", inst.u2.next_id); break;
      case QUEST: printf("  QUEST next=%d", inst.u2.next_id); break;
      case ANY: printf("    ANY next=%d", inst.u2.next_id); break;
      case ANYNL: printf("  ANYNL next=%d", inst.u2.next_id); break;
      case NOP: printf("    NOP next=%d", inst.u2.next_id); break;
      case BOL: {
        printf("    BOL c=");
        if (inst.u1.c == '\n') {
          printf("'\\n'");
        } else {
          printf("'%c'", inst.u1.c);
        }
        printf(", next=%d", inst.u2.next_id);
        break;
      }
      case EOL: {
        printf("    EOL c=");
        if (inst.u1.c == '\n') {
          printf("'\\n'");
        } else {
          printf("'%c'", inst.u1.c);
        }
        printf(", next=%d", inst.u2.next_id);
        break;
      }
      case CCLASS: printf(" CCLASS cls=%d , next=%d", inst.u1.cls_id, inst.u2.next_id); break;
      case NCCLASS: printf("NCCLASS cls=%d, next=%d", inst.u1.cls_id, inst.u2.next_id); break;
      case BOW: printf("    BOW next=%d", inst.u2.next_id); break;
      case NBOW: printf("   NBOW next=%d", inst.u2.next_id); break;
      case END: printf("    END"); break;
    }
    printf("\n");
  }

  printf("startinst_id=%d\n", _startinst_id);
  if (_startinst_ids.size() > 0) {
    printf("startinst_ids: [");
    for (size_t i = 0; i < _startinst_ids.size(); i++) {
      printf(" %d", _startinst_ids[i]);
    }
    printf("]\n");
  }

  int count = static_cast<int>(_classes.size());
  printf("\nClasses %d\n", count);
  for (int i = 0; i < count; i++) {
    const reclass& cls = _classes[i];
    auto const size    = static_cast<int>(cls.literals.size());
    printf("%2d: ", i);
    for (int j = 0; j < size; j += 2) {
      char32_t c1 = cls.literals[j];
      char32_t c2 = cls.literals[j + 1];
      if (c1 <= 32 || c1 >= 127 || c2 <= 32 || c2 >= 127) {
        printf("0x%02x-0x%02x", static_cast<unsigned>(c1), static_cast<unsigned>(c2));
      } else {
        printf("%c-%c", static_cast<char>(c1), static_cast<char>(c2));
      }
      if ((j + 2) < size) { printf(", "); }
    }
    printf("\n");
    if (cls.builtins) {
      int mask = cls.builtins;
      printf("   builtins(x%02X):", static_cast<unsigned>(mask));
      if (mask & CCLASS_W) printf(" \\w");
      if (mask & CCLASS_S) printf(" \\s");
      if (mask & CCLASS_D) printf(" \\d");
      if (mask & NCCLASS_W) printf(" \\W");
      if (mask & NCCLASS_S) printf(" \\S");
      if (mask & NCCLASS_D) printf(" \\D");
    }
    printf("\n");
  }
  if (_num_capturing_groups) { printf("Number of capturing groups: %d\n", _num_capturing_groups); }
}
#endif

}  // namespace detail
}  // namespace strings
}  // namespace cudf
