# CCS_Core_Code.pyx
# cython: boundscheck=False
# cython: wraparound=False
# cython: cdivision=True
# cython: nonecheck=False
# cython: initializedcheck=False

cdef int BOARD_SIZE = 11
cdef int EMPTY = 0
cdef int BLACK = 1
cdef int WHITE = 2

cdef class CCScore:
    cdef:
        public int difficulty
        public object board
        public int current_player
        public dict position_cache
        public dict move_cache
        public dict pattern_cache
        public dict zobrist_cache
        public int search_counter
        int center
        # 预计算的方向
        int[4][2] directions_array
        # 邻居偏移列表
        list neighbor_offsets
        # Zobrist哈希表 - 使用Python int避免溢出
        object zobrist_table
        object zobrist_hash  # 改为Python int

    def __init__(self, chess, difficulty):
        self.difficulty = difficulty
        self.board = chess
        self.current_player = BLACK
        self.center = BOARD_SIZE // 2
        self.position_cache = self._init_position_cache()
        self.move_cache = {}
        self.pattern_cache = {}
        self.zobrist_cache = {}
        self.search_counter = 0

        # 预计算方向数组
        cdef int i
        self.directions_array[0][0] = 1
        self.directions_array[0][1] = 0
        self.directions_array[1][0] = 0
        self.directions_array[1][1] = 1
        self.directions_array[2][0] = 1
        self.directions_array[2][1] = 1
        self.directions_array[3][0] = 1
        self.directions_array[3][1] = -1

        # 预计算邻居偏移（保持3格范围）
        self.neighbor_offsets = []
        cdef int dy, dx
        for dy in range(-3, 4):
            for dx in range(-3, 4):
                if dx != 0 or dy != 0:
                    self.neighbor_offsets.append((dx, dy))

        # 初始化Zobrist哈希表
        self._init_zobrist()
        self.zobrist_hash = self._calculate_zobrist()

    cdef void _init_zobrist(self):
        """初始化Zobrist哈希表"""
        cdef int y, x, player
        import random
        random.seed(42)

        # 使用Python列表存储，使用Python int避免溢出
        self.zobrist_table = []
        for y in range(BOARD_SIZE):
            row = []
            for x in range(BOARD_SIZE):
                col = []
                for player in range(2):
                    # 使用Python int，可以处理任意大的整数
                    col.append(random.getrandbits(64))
                row.append(col)
            self.zobrist_table.append(row)

    cdef object _calculate_zobrist(self):
        """计算当前棋盘的Zobrist哈希值，返回Python int"""
        cdef:
            object hash_val = 0  # 使用Python int
            int y, x
            int piece

        for y in range(BOARD_SIZE):
            for x in range(BOARD_SIZE):
                piece = self.board[y][x]
                if piece != EMPTY:
                    hash_val ^= self.zobrist_table[y][x][piece - 1]

        return hash_val

    cdef void _update_zobrist(self, int x, int y, int player):
        """更新Zobrist哈希值（落子后调用）"""
        if player != EMPTY:
            self.zobrist_hash ^= self.zobrist_table[y][x][player - 1]

    cdef void _remove_zobrist(self, int x, int y, int player):
        """移除Zobrist哈希值（提子后调用）"""
        if player != EMPTY:
            self.zobrist_hash ^= self.zobrist_table[y][x][player - 1]

    cdef dict _init_position_cache(self):
        cdef:
            dict cache = {}
            int center = self.center
            int x, y, distance_to_center, base_score
            set star_positions = {(3, 3), (3, 7), (5, 5), (7, 3), (7, 7)}

        for y in range(BOARD_SIZE):
            for x in range(BOARD_SIZE):
                distance_to_center = max(abs(x - center), abs(y - center))
                base_score = 30 - distance_to_center * 2

                if abs(x - y) <= 2 or abs(x + y - (BOARD_SIZE - 1)) <= 2:
                    base_score += 8

                if (x, y) in star_positions:
                    base_score += 5

                cache[(x, y)] = max(1, base_score)
        return cache

    # 将排序函数定义为cdef方法
    cdef int _get_position_key(self, tuple pos):
        """返回位置权重的负值用于排序"""
        return -self.position_cache[pos]

    cpdef list get_possible_moves(self):
        cdef:
            set moves
            int x, y, nx, ny, dx, dy
            bint has_pieces = False
            object board_hash = self.zobrist_hash  # 使用Python int
            list result
            int neighbor_count

        # 使用Zobrist哈希作为缓存键
        if board_hash in self.move_cache:
            return self.move_cache[board_hash]

        moves = set()

        # 快速检测是否有棋子
        for y in range(BOARD_SIZE):
            row = self.board[y]
            for x in range(BOARD_SIZE):
                if row[x] != EMPTY:
                    has_pieces = True
                    break
            if has_pieces:
                break

        if has_pieces:
            # 保持原来的搜索范围（3格以内）
            for y in range(BOARD_SIZE):
                row = self.board[y]
                for x in range(BOARD_SIZE):
                    if row[x] != EMPTY:
                        for dy in range(-3, 4):
                            for dx in range(-3, 4):
                                if dx == 0 and dy == 0:
                                    continue
                                nx = x + dx
                                ny = y + dy
                                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == EMPTY:
                                    moves.add((nx, ny))
        else:
            moves.add((self.center, self.center))

        # 优化排序：使用cdef方法避免闭包问题
        result = sorted(list(moves), key=self._get_position_key)
        self.move_cache[board_hash] = result
        return result

    cdef int _get_position_weight(self, tuple pos):
        """获取位置权重（用于排序）"""
        return -self.position_cache[pos]

    cpdef bint check_win_fast(self, int x, int y, int player):
        cdef:
            int dx, dy, i, nx, ny, count
            int idx

        for idx in range(4):
            dx = self.directions_array[idx][0]
            dy = self.directions_array[idx][1]
            count = 1

            # 正向检查
            for i in range(1, 5):
                nx = x + dx * i
                ny = y + dy * i
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == player:
                    count += 1
                else:
                    break

            # 反向检查
            for i in range(1, 5):
                nx = x - dx * i
                ny = y - dy * i
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == player:
                    count += 1
                else:
                    break

            if count >= 5:
                return True
        return False

    cdef int get_pattern_length(self, int x, int y, int player, int dx, int dy, int max_len=5):
        cdef:
            int count = 1
            int i, nx, ny

        # 正向
        for i in range(1, max_len + 1):
            nx = x + dx * i
            ny = y + dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == player:
                count += 1
            else:
                break

        # 反向
        for i in range(1, max_len + 1):
            nx = x - dx * i
            ny = y - dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == player:
                count += 1
            else:
                break
        return count

    cdef bint is_open_four(self, int x, int y, int player, int dx, int dy):
        cdef:
            int count = 1
            int i, nx, ny
            tuple forward_pos = None, backward_pos = None

        self.board[y][x] = player
        self._update_zobrist(x, y, player)

        # 正向检查
        for i in range(1, 5):
            nx = x + dx * i
            ny = y + dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                if self.board[ny][nx] == player:
                    count += 1
                else:
                    if self.board[ny][nx] == EMPTY and forward_pos is None:
                        forward_pos = (nx, ny)
                    break
            else:
                break

        # 反向检查
        for i in range(1, 5):
            nx = x - dx * i
            ny = y - dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                if self.board[ny][nx] == player:
                    count += 1
                else:
                    if self.board[ny][nx] == EMPTY and backward_pos is None:
                        backward_pos = (nx, ny)
                    break
            else:
                break

        self.board[y][x] = EMPTY
        self._remove_zobrist(x, y, player)

        return count >= 4

    cpdef double evaluate_pattern_detailed(self, int x, int y, int player):
        cdef:
            tuple cache_key = (x, y, player, self.zobrist_hash)  # 使用哈希值而不是棋盘字符串
            double total_score = 0
            double diagonal_weight = 1.2
            double dir_weight
            int idx, count, forward_empty, backward_empty
            int nx, ny, blocker_count
            bint is_diagonal

        # 尝试使用缓存键
        if cache_key in self.pattern_cache:
            return self.pattern_cache[cache_key]

        # 放置棋子并更新哈希
        self.board[y][x] = player
        self._update_zobrist(x, y, player)

        for idx in range(4):
            dx = self.directions_array[idx][0]
            dy = self.directions_array[idx][1]

            count = self.get_pattern_length(x, y, player, dx, dy)

            forward_empty = 0
            backward_empty = 0

            # 检查前方空格
            nx = x + dx * count
            ny = y + dy * count
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                if self.board[ny][nx] == EMPTY:
                    forward_empty = 1

            # 检查后方空格
            nx = x - dx * count
            ny = y - dy * count
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                if self.board[ny][nx] == EMPTY:
                    backward_empty = 1

            dir_weight = diagonal_weight if dy != 0 and dx != 0 else 1.0
            is_diagonal = (dy != 0 and dx != 0)

            # 模式评分（保持原逻辑不变）
            if count >= 5:
                total_score += 10000000 * dir_weight
            elif count == 4:
                if forward_empty and backward_empty:
                    total_score += 200000 * dir_weight
                elif forward_empty or backward_empty:
                    blocker_count = self._check_blocker_count(x, y, player, dx, dy, count)
                    if blocker_count <= 1:
                        total_score += 120000 * dir_weight
                    else:
                        total_score += 60000 * dir_weight
                else:
                    total_score += 20000 * dir_weight
            elif count == 3:
                if forward_empty and backward_empty:
                    total_score += 40000 * dir_weight
                elif forward_empty or backward_empty:
                    total_score += 20000 * dir_weight
                else:
                    total_score += 3000 * dir_weight
            elif count == 2:
                if forward_empty and backward_empty:
                    total_score += 5000 * dir_weight
                elif forward_empty or backward_empty:
                    total_score += 1500 * dir_weight
                else:
                    total_score += 200 * dir_weight
            elif count == 1:
                total_score += 50 * dir_weight

            if is_diagonal and count >= 3:
                total_score += count * 500

        # 恢复棋盘状态
        self.board[y][x] = EMPTY
        self._remove_zobrist(x, y, player)

        # 缓存结果
        self.pattern_cache[cache_key] = total_score

        # 定期清理缓存
        if len(self.pattern_cache) > 50000:
            self.pattern_cache.clear()

        return total_score

    cdef int _check_blocker_count(self, int x, int y, int player, int dx, int dy, int count):
        cdef:
            int blocker_count = 0
            int nx, ny

        nx = x + dx * count
        ny = y + dy * count
        if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
            if self.board[ny][nx] != EMPTY and self.board[ny][nx] != player:
                blocker_count += 1
        else:
            blocker_count += 1

        nx = x - dx * count
        ny = y - dy * count
        if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
            if self.board[ny][nx] != EMPTY and self.board[ny][nx] != player:
                blocker_count += 1
        else:
            blocker_count += 1

        return blocker_count

    cdef int _check_potential(self, int x, int y, int player, int dx, int dy, int count):
        """检查发展潜力"""
        cdef:
            int potential = 0
            int step, test_x, test_y

        self.board[y][x] = player
        self._update_zobrist(x, y, player)

        for step in range(1, 3):
            test_x = x + dx * (count + step - 1)
            test_y = y + dy * (count + step - 1)
            if 0 <= test_x < BOARD_SIZE and 0 <= test_y < BOARD_SIZE:
                if self.board[test_y][test_x] == EMPTY:
                    potential += 1

        self.board[y][x] = EMPTY
        self._remove_zobrist(x, y, player)
        return potential

    cpdef double evaluate_position_comprehensive(self, int x, int y, int player):
        cdef:
            double score
            double pattern_score
            double connection_score = 0
            double strategic_value = 0
            int dx, dy, nx, ny, distance_weight, liberty = 0
            int ddx, ddy, neighbor_count
            int idx

        # 位置基础分
        score = self.position_cache[(x, y)] * 15

        # 棋型评分
        pattern_score = self.evaluate_pattern_detailed(x, y, player)
        score += pattern_score

        # 连接性评分（保持原范围2格）
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                if dx == 0 and dy == 0:
                    continue
                nx = x + dx
                ny = y + dy
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                    if self.board[ny][nx] == player:
                        distance_weight = 4 - (max(abs(dx), abs(dy)))
                        connection_score += 30 * distance_weight

        score += connection_score * 2

        # 自由度评分（保持原范围2格）
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                if dx == 0 and dy == 0:
                    continue
                nx = x + dx
                ny = y + dy
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and self.board[ny][nx] == EMPTY:
                    liberty += 1
        score += liberty * 60

        # 战略价值（保持原范围2格）
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                nx = x + dx
                ny = y + dy
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                    if self.board[ny][nx] == player:
                        strategic_value += 40
                    elif self.board[ny][nx] == EMPTY:
                        strategic_value += 10

        # 邻居棋型价值（保持原范围1格）
        for dy in range(-1, 2):
            for dx in range(-1, 2):
                nx = x + dx
                ny = y + dy
                if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE:
                    if self.board[ny][nx] == player:
                        for idx in range(4):
                            ddx = self.directions_array[idx][0]
                            ddy = self.directions_array[idx][1]
                            neighbor_count = self.get_pattern_length(nx, ny, player, ddx, ddy, 3)
                            if neighbor_count >= 3:
                                strategic_value += 80

        score += strategic_value
        return score

    cpdef double enhanced_minimax(self, int depth, bint is_maximizing, double alpha, double beta, int player):
        cdef:
            int opponent
            list possible_moves
            int search_width
            list move_evals
            double eval_score, max_score, min_score, defense_score, search_score, attack_potential, total_score
            int x, y
            tuple move
            int num_moves, i

        # 保持搜索深度不变
        if depth == 0:
            return 0

        opponent = WHITE if player == BLACK else BLACK
        possible_moves = self.get_possible_moves()

        if not possible_moves:
            return 0

        # 动态搜索宽度（保持原逻辑）
        if is_maximizing:
            search_width = max(5, 12 - depth * 2)
        else:
            search_width = max(4, 10 - depth * 2)

        # 评估候选移动
        move_evals = []
        num_moves = min(search_width + 5, len(possible_moves))

        for i in range(num_moves):
            x, y = possible_moves[i]
            if is_maximizing:
                eval_score = self.evaluate_position_comprehensive(x, y, player)
            else:
                eval_score = self.evaluate_position_comprehensive(x, y, opponent)
            move_evals.append((eval_score, x, y))

        move_evals.sort(reverse=True)

        if is_maximizing:
            max_score = -1e100
            num_moves = min(search_width, len(move_evals))

            for i in range(num_moves):
                eval_score, x, y = move_evals[i]

                # 落子
                self.board[y][x] = player
                self._update_zobrist(x, y, player)

                # 检查是否获胜
                if self.check_win_fast(x, y, player):
                    self.board[y][x] = EMPTY
                    self._remove_zobrist(x, y, player)
                    return 10000000 + depth * 1000

                # 计算防守分值
                defense_score = self.evaluate_position_comprehensive(x, y, opponent) * 0.6

                # 递归搜索
                search_score = self.enhanced_minimax(depth - 1, False, alpha, beta, player)
                total_score = eval_score + defense_score + search_score * 0.4

                # 恢复棋盘
                self.board[y][x] = EMPTY
                self._remove_zobrist(x, y, player)

                if total_score > max_score:
                    max_score = total_score
                if total_score > alpha:
                    alpha = total_score
                if beta <= alpha:
                    break

            return max_score
        else:
            min_score = 1e100
            num_moves = min(search_width, len(move_evals))

            for i in range(num_moves):
                eval_score, x, y = move_evals[i]

                # 对手落子
                self.board[y][x] = opponent
                self._update_zobrist(x, y, opponent)

                # 检查对手是否获胜
                if self.check_win_fast(x, y, opponent):
                    self.board[y][x] = EMPTY
                    self._remove_zobrist(x, y, opponent)
                    return -10000000 - depth * 1000

                # 计算攻击潜力
                attack_potential = self.evaluate_position_comprehensive(x, y, opponent) * 0.5

                # 递归搜索
                search_score = self.enhanced_minimax(depth - 1, True, alpha, beta, player)
                total_score = -eval_score * 0.7 - attack_potential + search_score * 0.4

                # 恢复棋盘
                self.board[y][x] = EMPTY
                self._remove_zobrist(x, y, opponent)

                if total_score < min_score:
                    min_score = total_score
                if total_score < beta:
                    beta = total_score
                if beta <= alpha:
                    break

            return min_score

    cpdef tuple find_best_move(self):
        cdef:
            int opponent
            list possible_moves
            int search_depth
            list move_scores
            double attack_score, defense_score, total_score
            int x, y
            int top_n, center_dist
            tuple best_move = None
            double best_score = -1e100
            double search_score, base_score, final_score
            tuple max_pos
            int max_weight = -1
            int num_candidates, i

        opponent = WHITE if self.current_player == BLACK else BLACK
        possible_moves = self.get_possible_moves()

        if not possible_moves:
            return (self.center, self.center)

        # 检查直接的获胜移动
        for i in range(len(possible_moves)):
            x, y = possible_moves[i]
            if self.check_win_fast(x, y, self.current_player):
                return (x, y)

        # 检查需要防守的移动
        for i in range(len(possible_moves)):
            x, y = possible_moves[i]
            if self.check_win_fast(x, y, opponent):
                return (x, y)

        # 搜索深度等于难度
        search_depth = self.difficulty

        # 评估所有可能的移动
        move_scores = []
        for i in range(len(possible_moves)):
            x, y = possible_moves[i]
            attack_score = self.evaluate_position_comprehensive(x, y, self.current_player)
            defense_score = self.evaluate_position_comprehensive(x, y, opponent)
            total_score = attack_score * 1.0 + defense_score * 0.7

            center_dist = max(abs(x - self.center), abs(y - self.center))
            total_score += (BOARD_SIZE - center_dist) * 15
            move_scores.append((total_score, (x, y)))

        move_scores.sort(reverse=True)

        # 选择前N个候选进行深度搜索
        top_n = min(7, len(move_scores))
        top_candidates = [score[1] for score in move_scores[:top_n]]

        # 对候选移动进行深度搜索
        for i in range(len(top_candidates)):
            x, y = top_candidates[i]

            # 落子
            self.board[y][x] = self.current_player
            self._update_zobrist(x, y, self.current_player)

            # 深度搜索
            search_score = self.enhanced_minimax(search_depth, False, -1e100, 1e100, self.current_player)

            # 恢复棋盘
            self.board[y][x] = EMPTY
            self._remove_zobrist(x, y, self.current_player)

            base_score = move_scores[0][0] if move_scores else 0
            final_score = self.evaluate_position_comprehensive(x, y, self.current_player) + search_score * 0.5

            if final_score > best_score:
                best_score = final_score
                best_move = (x, y)

        # 如果没有找到最佳移动，使用评估最高的
        if best_move is None and move_scores:
            best_move = move_scores[0][1]

        # 最后的后备方案
        if best_move is None:
            max_pos = possible_moves[0]
            max_weight = self.position_cache[max_pos]
            for i in range(1, len(possible_moves)):
                pos = possible_moves[i]
                weight = self.position_cache[pos]
                if weight > max_weight:
                    max_weight = weight
                    max_pos = pos
            best_move = max_pos

        # 清理缓存以避免内存泄漏
        if len(self.pattern_cache) > 100000:
            self.pattern_cache.clear()
        if len(self.move_cache) > 1000:
            self.move_cache.clear()

        return best_move

# 模块级别的函数（保持原样）
cpdef bint check_win(board, int x, int y):
    cdef:
        int player
        int dx, dy, i, nx, ny, count
        list directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
        int idx

    if board[y][x] == EMPTY:
        return False

    player = board[y][x]

    for idx in range(4):
        dx = directions[idx][0]
        dy = directions[idx][1]
        count = 1

        for i in range(1, 5):
            nx = x + dx * i
            ny = y + dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and board[ny][nx] == player:
                count += 1
            else:
                break

        for i in range(1, 5):
            nx = x - dx * i
            ny = y - dy * i
            if 0 <= nx < BOARD_SIZE and 0 <= ny < BOARD_SIZE and board[ny][nx] == player:
                count += 1
            else:
                break

        if count >= 5:
            return True

    return False