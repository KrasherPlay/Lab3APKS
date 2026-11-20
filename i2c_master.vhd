library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Модуль I2C Master (Варіант 23: I2C / VHDL)
-- Підтримує передачу (Tx) та прийом (Rx) 8-бітних даних з 7-бітною адресацією
entity i2c_master is
    Generic (
        INPUT_CLK_FREQ : integer := 50_000_000; -- Вхідна частота ПЛІС (50 МГц)
        BUS_CLK_FREQ   : integer := 100_000     -- Частота шини I2C (100 кГц - Standard Mode)
    );
    Port (
        clk       : in    STD_LOGIC;                    -- Системний тактовий сигнал
        reset     : in    STD_LOGIC;                    -- Асинхронний/синхронний скид (активний '1')
        ena       : in    STD_LOGIC;                    -- Сигнал запуску транзакції ('1' - старт)
        addr      : in    STD_LOGIC_VECTOR(6 downto 0); -- 7-бітна адреса ведомого (Slave)
        rw        : in    STD_LOGIC;                    -- Режим: '0' - запис (Tx), '1' - читання (Rx)
        data_wr   : in    STD_LOGIC_VECTOR(7 downto 0); -- Байт даних для передачі на Slave
        busy      : out   STD_LOGIC;                    -- Прапорець зайнятості контролера
        data_rd   : out   STD_LOGIC_VECTOR(7 downto 0); -- Прийнятий байт даних від Slave
        ack_error : out   STD_LOGIC;                    -- Прапорець помилки підтвердження (NACK)
        sda       : inout STD_LOGIC;                    -- Двонаправлена лінія даних I2C
        scl       : inout STD_LOGIC                     -- Лінія тактування I2C
    );
end i2c_master;

architecture Behavioral of i2c_master is

    -- Розрахунок дільника частоти для формування 4 фаз одного періоду SCL
    constant DIVIDER : integer := (INPUT_CLK_FREQ / BUS_CLK_FREQ) / 4;

    -- Стани скінченного автомата (FSM) протоколу I2C
    type state_type is (
        IDLE,       -- Очікування запуску
        START,      -- Формування умови START
        ADDR_RW,    -- Передача 7 біт адреси та 1 біта R/W
        ACK_ADDR,   -- Очікування підтвердження ACK адреси від Slave
        DATA_TX,    -- Передача 8 біт даних (режим запису)
        DATA_RX,    -- Прийом 8 біт даних (режим читання)
        ACK_DATA,   -- Отримання ACK (при записі) або відправка NACK (при читанні)
        STOP        -- Формування умови STOP
    );
    signal state : state_type := IDLE;

    signal count       : integer range 0 to DIVIDER - 1 := 0; -- Лічильник дільника
    signal phase       : integer range 0 to 3 := 0;           -- Поточна фаза такту SCL (0..3)
    signal bit_cnt     : integer range 0 to 7 := 7;           -- Лічильник бітів у байті (від 7 до 0)
    signal addr_rw_reg : STD_LOGIC_VECTOR(7 downto 0) := (others => '0'); -- Буфер адреси + R/W
    signal data_tx_reg : STD_LOGIC_VECTOR(7 downto 0) := (others => '0'); -- Буфер передачі
    signal data_rx_reg : STD_LOGIC_VECTOR(7 downto 0) := (others => '0'); -- Буфер прийому

    signal sda_out     : STD_LOGIC := '1'; -- Внутрішній сигнал керування SDA ('0' або 'Z')
    signal scl_out     : STD_LOGIC := '1'; -- Внутрішній сигнал керування SCL ('0' або '1')

begin

    -- Реалізація виходів з відкритим стоком (Open-Drain):
    -- '0' притягує лінію до землі, '1' переводить у високоімпедансний стан 'Z' (підтяжка)
    sda <= '0' when sda_out = '0' else 'Z';
    scl <= '0' when scl_out = '0' else 'Z';

    -- Основний синхронний процес скінченного автомата та генератора фаз
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state       <= IDLE;
                count       <= 0;
                phase       <= 0;
                bit_cnt     <= 7;
                sda_out     <= '1';
                scl_out     <= '1';
                busy        <= '0';
                ack_error   <= '0';
                data_rd     <= (others => '0');
            else
                -- Генерація 4-фазних часових інтервалів для формування фронту/спаду SCL
                if state = IDLE then
                    count <= 0;
                    phase <= 0;
                else
                    if count = DIVIDER - 1 then
                        count <= 0;
                        if phase = 3 then
                            phase <= 0;
                        else
                            phase <= phase + 1;
                        end if;
                    else
                        count <= count + 1;
                    end if;
                end if;

                -- Логіка переходів FSM при зміні фаз (на початку кожної фази: count = 0)
                case state is
                    when IDLE =>
                        sda_out <= '1';
                        scl_out <= '1';
                        if ena = '1' then
                            busy        <= '1';
                            ack_error   <= '0';
                            addr_rw_reg <= addr & rw; -- Формування 8-бітного заголовка
                            data_tx_reg <= data_wr;
                            state       <= START;
                        else
                            busy <= '0';
                        end if;

                    when START =>
                        -- Умова START: SDA падає в '0', поки SCL утримується в '1'
                        if count = 0 then
                            case phase is
                                when 0 => sda_out <= '1'; scl_out <= '1';
                                when 1 => sda_out <= '0'; scl_out <= '1'; -- Спад SDA при SCL=1
                                when 2 => scl_out <= '0';                 -- Підготовка до передачі бітів
                                when 3 => bit_cnt <= 7; state <= ADDR_RW;
                            end case;
                        end if;

                    when ADDR_RW =>
                        -- Передача 7 біт адреси та 1 біта R/W (коли SCL=0, міняємо SDA)
                        if count = 0 then
                            case phase is
                                when 0 =>
                                    scl_out <= '0';
                                    sda_out <= addr_rw_reg(bit_cnt);
                                when 1 =>
                                    scl_out <= '1'; -- Стробування біта на шині
                                when 2 =>
                                    scl_out <= '1';
                                when 3 =>
                                    scl_out <= '0';
                                    if bit_cnt = 0 then
                                        state <= ACK_ADDR;
                                    else
                                        bit_cnt <= bit_cnt - 1;
                                    end if;
                            end case;
                        end if;

                    when ACK_ADDR =>
                        -- Відпускаємо SDA ('1' -> 'Z') та зчитуємо ACK від Slave при SCL=1
                        if count = 0 then
                            case phase is
                                when 0 =>
                                    scl_out <= '0';
                                    sda_out <= '1'; -- Перехід у Z-стан
                                when 1 =>
                                    scl_out <= '1';
                                when 2 =>
                                    -- Перевірка рівня на лінії SDA (має бути '0')
                                    if sda /= '0' then
                                        ack_error <= '1';
                                    end if;
                                when 3 =>
                                    scl_out <= '0';
                                    bit_cnt <= 7;
                                    if addr_rw_reg(0) = '0' then
                                        state <= DATA_TX; -- Перехід до передачі байта
                                    else
                                        state <= DATA_RX; -- Перехід до прийому байта
                                    end if;
                            end case;
                        end if;

                    when DATA_TX =>
                        -- Послідовна передача 8 біт даних (Tx)
                        if count = 0 then
                            case phase is
                                when 0 =>
                                    scl_out <= '0';
                                    sda_out <= data_tx_reg(bit_cnt);
                                when 1 =>
                                    scl_out <= '1';
                                when 2 =>
                                    scl_out <= '1';
                                when 3 =>
                                    scl_out <= '0';
                                    if bit_cnt = 0 then
                                        state <= ACK_DATA;
                                    else
                                        bit_cnt <= bit_cnt - 1;
                                    end if;
                            end case;
                        end if;

                    when DATA_RX =>
                        -- Послідовний прийом 8 біт даних (Rx) від Slave
                        if count = 0 then
                            case phase is
                                when 0 =>
                                    scl_out <= '0';
                                    sda_out <= '1'; -- Відпускаємо SDA для ведомого пристрою
                                when 1 =>
                                    scl_out <= '1';
                                when 2 =>
                                    -- Зчитування біта даних при високому SCL
                                    data_rx_reg(bit_cnt) <= To_X01(sda);
                                when 3 =>
                                    scl_out <= '0';
                                    if bit_cnt = 0 then
                                        data_rd <= data_rx_reg;
                                        state   <= ACK_DATA;
                                    else
                                        bit_cnt <= bit_cnt - 1;
                                    end if;
                            end case;
                        end if;

                    when ACK_DATA =>
                        -- При записі чекаємо ACK від Slave; при читанні Master видає NACK ('1')
                        if count = 0 then
                            case phase is
                                when 0 =>
                                    scl_out <= '0';
                                    sda_out <= '1'; -- NACK після одного байта або відпускання для ACK
                                when 1 =>
                                    scl_out <= '1';
                                when 2 =>
                                    if addr_rw_reg(0) = '0' and sda /= '0' then
                                        ack_error <= '1';
                                    end if;
                                when 3 =>
                                    scl_out <= '0';
                                    state   <= STOP;
                            end case;
                        end if;

                    when STOP =>
                        -- Умова STOP: SDA переходить з '0' в '1' при утриманні SCL = '1'
                        if count = 0 then
                            case phase is
                                when 0 => sda_out <= '0'; scl_out <= '0';
                                when 1 => sda_out <= '0'; scl_out <= '1';
                                when 2 => sda_out <= '1'; scl_out <= '1'; -- Фронт SDA при SCL=1
                                when 3 => busy <= '0'; state <= IDLE;
                            end case;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;