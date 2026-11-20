library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Тестовий стенд (Testbench) для верифікації модуля i2c_master (Варіант 23: I2C / VHDL)
entity i2c_master_tb is
end i2c_master_tb;

architecture Behavioral of i2c_master_tb is

    -- Підключення тестованого компонента (DUT - Design Under Test)
    component i2c_master
        Generic (
            INPUT_CLK_FREQ : integer := 50_000_000;
            BUS_CLK_FREQ   : integer := 100_000
        );
        Port (
            clk       : in    STD_LOGIC;
            reset     : in    STD_LOGIC;
            ena       : in    STD_LOGIC;
            addr      : in    STD_LOGIC_VECTOR(6 downto 0);
            rw        : in    STD_LOGIC;
            data_wr   : in    STD_LOGIC_VECTOR(7 downto 0);
            busy      : out   STD_LOGIC;
            data_rd   : out   STD_LOGIC_VECTOR(7 downto 0);
            ack_error : out   STD_LOGIC;
            sda       : inout STD_LOGIC;
            scl       : inout STD_LOGIC
        );
    end component;

    -- Сигнали для підключення до DUT
    signal clk       : STD_LOGIC := '0';
    signal reset     : STD_LOGIC := '0';
    signal ena       : STD_LOGIC := '0';
    signal addr      : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal rw        : STD_LOGIC := '0';
    signal data_wr   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal busy      : STD_LOGIC;
    signal data_rd   : STD_LOGIC_VECTOR(7 downto 0);
    signal ack_error : STD_LOGIC;

    -- Шина I2C з резисторами підтяжки (Pull-up)
    signal sda       : STD_LOGIC := 'H';
    signal scl       : STD_LOGIC := 'H';
    signal slave_sda : STD_LOGIC := 'Z'; -- Лінія керування від імітатора Slave

    constant CLK_PERIOD : time := 20 ns; -- Тактова частота 50 МГц

begin

    -- Імітація підтягуючих резисторів (Weak High 'H') та керування від Slave
    sda <= 'H';
    scl <= 'H';
    sda <= slave_sda;

    -- Екземпляр тестованого модуля I2C Master
    uut: i2c_master
        generic map (
            INPUT_CLK_FREQ => 50_000_000,
            BUS_CLK_FREQ   => 100_000
        )
        port map (
            clk       => clk,
            reset     => reset,
            ena       => ena,
            addr      => addr,
            rw        => rw,
            data_wr   => data_wr,
            busy      => busy,
            data_rd   => data_rd,
            ack_error => ack_error,
            sda       => sda,
            scl       => scl
        );

    -- 1. Генерація системного тактового сигналу CLK (50 МГц)[cite: 6]
    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- 2. Процес подачі тестових стимулів (перевірка Tx та Rx)[cite: 6]
    stim_proc : process
    begin
        -- Початкове скидання системи
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait for 200 ns;

        -- ТЕСТ 1: Запис даних (Tx) -> Адреса 0x53 ("1010011"), Дані 0xA5 ("10100101")
        addr    <= "1010011";
        rw      <= '0';        -- Режим запису (Write)
        data_wr <= "10100101"; -- Тестовий байт 0xA5
        ena     <= '1';
        wait for 20 us;
        ena     <= '0';

        -- Очікування завершення транзакції запису
        wait until busy = '0';
        wait for 30 us;

        -- ТЕСТ 2: Читання даних (Rx) -> Адреса 0x53 ("1010011"), очікуємо байт 0x3C
        addr    <= "1010011";
        rw      <= '1';        -- Режим читання (Read)
        ena     <= '1';
        wait for 20 us;
        ena     <= '0';

        -- Очікування завершення транзакції читання
        wait until busy = '0';
        wait for 30 us;

        -- Зупинка симуляції
        assert false report "Simulation Finished Successfully!" severity failure;
    end process;

    -- 3. Імітатор ведомого пристрою (I2C Slave) на шині[cite: 6]
    slave_sim : process
        variable slave_rx_data : std_logic_vector(7 downto 0) := "00111100"; -- 0x3C для відправки у Master
    begin
        slave_sda <= 'Z';
        -- Чекаємо умову START (спад SDA при високому SCL)
        wait until falling_edge(sda) and (scl /= '0');

        -- Пропускаємо 8 тактів адреси + R/W
        for i in 0 to 7 loop
            wait until falling_edge(scl);
        end loop;

        -- 9-й такт: відправляємо ACK (притягуємо SDA до '0')
        slave_sda <= '0';
        wait until falling_edge(scl);
        slave_sda <= 'Z';

        if rw = '0' then
            -- Режим запису: пропускаємо 8 тактів даних від Master
            for i in 0 to 7 loop
                wait until falling_edge(scl);
            end loop;
            -- Відправляємо другий ACK після прийому байта
            slave_sda <= '0';
            wait until falling_edge(scl);
            slave_sda <= 'Z';
        else
            -- Режим читання: передаємо 8 біт (0x3C) у Master
            for i in 7 downto 0 loop
                slave_sda <= slave_rx_data(i);
                wait until falling_edge(scl);
            end loop;
            slave_sda <= 'Z'; -- Відпускаємо SDA для NACK від Master
        end if;
    end process;

end Behavioral;