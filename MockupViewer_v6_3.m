%% =======================================================================
%                      MAIN SCRIPT EXECUTION
% ========================================================================
function MockupViewer()
    clear; close all; clc;
    config = createConfig();
    [fid, config] = initializeLogging(config);
    handles = initializePlots(config);
    appState = initializeState(config);
    mainLoop(config, handles, appState, fid);
end

%% =======================================================================
%                      1. CONFIGURATION
% ========================================================================
function config = createConfig()
    disp('Initializing configuration...');
    config.serial.port = 'COM5'; config.serial.baudRate = 250000;
    config.trigger_serial.port = 'COM11'; config.trigger_serial.baudRate = 9600;
    config.tcpIP = '0.0.0.0'; config.tcpPort = 1234;
    config.useNumpadTrigger = true;`
    config.savefolderPath = '.\logs';
    config.eeg.id = 1; config.fnirs.id = [2 3 4 5 6];
    config.eeg.fs = 250; config.fnirs.fs = 50;
    config.plot.batchSize = 30; config.plot.xRangeSec = 10;
    config.plot.fixedYlim = true;
    config.plot.eegMaximumNumPoints = config.eeg.fs * config.plot.xRangeSec;
    % config.fnirs.pairs = [1 1; 2 1; 1 2; 2 2; 2 3; 3 2; 3 3; 4 3; 3 4; 4 4; 4 5; 5 4; 5 5];
    % config.fnirs.pairs = [1 1; 2 1; 3 1; 4 1; 5 1];
    config.fnirs.pairs = [1 1; 1 2; 1 3; 1 4; 1 5];

    config.filter.apply = true;
    [config.filter.b_n60, config.filter.a_n60] = butter(3, [59 61]/(config.eeg.fs/2), 'stop');
    [config.filter.b_n50, config.filter.a_n50] = butter(3, [49 51]/(config.eeg.fs/2), 'stop');
    [config.filter.b_bp,  config.filter.a_bp]  = butter(3, [1 40]/(config.eeg.fs/2), 'bandpass');
    [config.filter.b_lp,  config.filter.a_lp]  = butter(3, 1.5/(config.fnirs.fs/2), 'low');
end

%% =======================================================================
%                      2. INITIALIZATION
% ========================================================================
function [fid, config] = initializeLogging(config)
    disp('Initializing logging...');
    if ~isdir(config.savefolderPath), mkdir(config.savefolderPath); end
    config.csvFileName = fullfile(config.savefolderPath, sprintf('EEG_fNIRS_%s.csv', datestr(now, 'yyyymmdd_HHMMSS')));
    fid = fopen(config.csvFileName, 'w');
    header_line = strjoin(["Timestamp", "PacketType", "Counter", "Trigger", "Ch" + (1:10)], ",");
    fprintf(fid, '%s\n', header_line);
end

function handles = initializePlots(config)
    disp('Initializing plots...');
    handles.eeg_figure = figure('Name','7 ch EEG + Trigger','NumberTitle','off');
    tiledlayout(9, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    handles = createStatusIndicators(handles);
    handles = createEEGPlot(handles, config);
    handles = createTriggerPlot(handles, config);
    handles = createFNIRSPlot(handles, config);
end

function appState = initializeState(config)
    disp('Initializing application state...');
    try, appState.s = serialport(config.serial.port, config.serial.baudRate); configureTerminator(appState.s, "LF");
    catch ME, warning('Failed to open device serial port %s. Error: %s', config.serial.port, ME.message); appState.s = []; end
    try, appState.trigger_s = serialport(config.trigger_serial.port, config.trigger_serial.baudRate);
    catch ME, warning('Failed to open trigger serial port %s. Error: %s', config.trigger_serial.port, ME.message); appState.trigger_s = []; end
    try, appState.tcp = tcpserver(config.tcpIP, config.tcpPort, "Timeout", 1);
    catch ME, warning('Failed to create TCP server on %s:%d. Error: %s', config.tcpIP, config.tcpPort, ME.message); appState.tcp = []; end
    
    appState.buffer = uint32([]);
    appState.packetOrder = [1 2 1 3 1 4 1 5 1 6];
    appState.packetIndex = 1;
    appState.sampleCounters = zeros(6, 1);
    appState.visualTriggerQueue = struct('value', {}, 'sample', {});
    appState.loggingTriggerQueue = [];
    
    appState.triggerForNextPackets = -1;
    appState.triggerApplyCounter = 0;
    
    for i = 1:6, appState.plotData(i).x = []; appState.plotData(i).y = []; end
    appState.filter.zi_n60 = []; appState.filter.zi_n50 = []; appState.filter.zi_bp = [];
    appState.filter.zi_lp = cell(6,1); for i=1:6, appState.filter.zi_lp{i} = []; end    
end

%% =======================================================================
%                      3. MAIN LOOP
% ========================================================================
function mainLoop(config, handles, appState, fid)
    disp('Receiving data... Ctrl+C to stop.');
    if isempty(appState.s) || ~isvalid(appState.s)
        errordlg('Device Serial Port connection failed. Program will exit.', 'Critical Connection Error', 'modal');
        uiwait(gcf); cleanup(appState, fid, handles); return;
    end
    
    handles.eeg_figure.UserData.appState = appState;
    if config.useNumpadTrigger
        disp('Numpad trigger is ENABLED.');
        handles.eeg_figure.KeyPressFcn = @(src, event) keyPressCallback(src, event, config);
    end
    
    try
        while isgraphics(handles.eeg_figure)
            appState = handles.eeg_figure.UserData.appState;
            
            if ~isempty(appState.s) && isvalid(appState.s) && appState.s.NumBytesAvailable > 0
                newData = read(appState.s, appState.s.NumBytesAvailable, 'uint8');
                appState.buffer = [appState.buffer; newData(:)];
            end
            
            appState = checkAndProcessTriggers(appState, config);
            appState = processDataBuffer(appState, config, handles, fid);
            appState = plotQueuedTriggers(handles, appState);
            
            updateStatusIndicators(handles, appState);
            handles.eeg_figure.UserData.appState = appState;
            pause(0.01);
        end
    catch ME, fprintf(2, 'Error in main loop: %s at line %d of %s\n', ME.message, ME.stack(1).line, ME.stack(1).name); end
    cleanup(appState, fid, handles);
end

%% =======================================================================
%                      4. CORE LOGIC MODULES
% ========================================================================
function appState = processDataBuffer(appState, config, handles, fid)
    if appState.triggerApplyCounter == 0 && ~isempty(appState.loggingTriggerQueue)
        newTrigger = appState.loggingTriggerQueue(1); appState.loggingTriggerQueue(1) = [];
        appState.triggerForNextPackets = newTrigger;
        appState.triggerApplyCounter = 2;
    end
    while length(appState.buffer) >= 24
        packet = appState.buffer(1:24); appState.buffer(1:24) = [];
        packetType = appState.packetOrder(appState.packetIndex);
        appState.sampleCounters(packetType) = appState.sampleCounters(packetType) + 1;
        if packetType == config.eeg.id, channelData = extractType1Data(packet);
        else, channelData = extractType2To6Data(packet); end
        
        triggerForCurrentPacket = -1; 
        if appState.triggerApplyCounter > 0
            triggerForCurrentPacket = appState.triggerForNextPackets;
            appState.triggerApplyCounter = appState.triggerApplyCounter - 1;
            if appState.triggerApplyCounter == 0, appState.triggerForNextPackets = -1; end
        end
        writeLogEntry(fid, config, packetType, channelData, appState.sampleCounters, triggerForCurrentPacket);
        
        appState.plotData(packetType).x(end+1) = appState.sampleCounters(packetType);
        appState.plotData(packetType).y(end+1, :) = channelData;
        appState.packetIndex = mod(appState.packetIndex, length(appState.packetOrder)) + 1;
        if size(appState.plotData(packetType).y, 1) >= config.plot.batchSize
            appState = updateGraphics(config, handles, appState, packetType);
        end
    end
end

function appState = checkAndProcessTriggers(appState, config)
    currentEegSample = appState.sampleCounters(config.eeg.id);
    
    if ~isempty(appState.trigger_s) && isvalid(appState.trigger_s) && appState.trigger_s.NumBytesAvailable > 0
        triggerValue = read(appState.trigger_s, appState.trigger_s.NumBytesAvailable, 'uint8');
        if ~isempty(triggerValue)
            finalTrigger = double(triggerValue(end));
            if ~isnan(finalTrigger) && finalTrigger >= 0
                appState.visualTriggerQueue(end+1) = struct('value', finalTrigger, 'sample', currentEegSample);
                appState.loggingTriggerQueue(end+1) = finalTrigger;
                fprintf('Serial Trigger %d queued at sample %d.\n', finalTrigger, currentEegSample);
            end
        end
    end

    if ~isempty(appState.tcp) && isvalid(appState.tcp) && appState.tcp.Connected && appState.tcp.NumBytesAvailable > 0
        try
            rxT = read(appState.tcp, appState.tcp.NumBytesAvailable, 'uint8');
            if ~isempty(rxT)
                triggerValue = str2double(char(rxT(end)));
                if ~isnan(triggerValue) && triggerValue >= 0
                    appState.visualTriggerQueue(end+1) = struct('value', triggerValue, 'sample', currentEegSample);
                    appState.loggingTriggerQueue(end+1) = triggerValue;
                    fprintf('TCP Trigger %d queued at sample %d.\n', triggerValue, currentEegSample);
                end
            end
        catch, end % str2double 실패 시 오류 무시
    end
end

function keyPressCallback(src, event, config)
    key = event.Key;
    if strcmp(key, 'numpad0') || strcmp(key, '0')
        triggerValue = 0;
    elseif startsWith(key, 'numpad')
        triggerValue = str2double(key(7:end));
    elseif length(key) == 1 && any(key == '1':'9')
        triggerValue = str2double(key);
    else
        return;
    end

    if isnan(triggerValue) || triggerValue < 0 || triggerValue > 9, return; end
    
    appState = src.UserData.appState;
    currentEegSample = appState.sampleCounters(config.eeg.id);
    
    appState.visualTriggerQueue(end+1) = struct('value', triggerValue, 'sample', currentEegSample);
    appState.loggingTriggerQueue(end+1) = triggerValue;
    
    src.UserData.appState = appState;
    fprintf('Manual Trigger %d queued at sample %d.\n', triggerValue, currentEegSample);
end

%% =======================================================================
%                      5. PLOTTING SUB-MODULES
% ========================================================================
function handles = createStatusIndicators(handles)
    ax = nexttile([1 1]); set(ax, 'Visible', 'off'); ylim(ax, [0 1]); xlim(ax, [0 1]);
    handles.indicators.tcp = text(ax, 0.1, 0.5, 'TCP: Init...', 'FontSize', 10, 'FontWeight', 'bold', 'Color', [0.8 0.5 0]);
    handles.indicators.deviceSerial = text(ax, 0.4, 0.5, 'Device: Init...', 'FontSize', 10, 'FontWeight', 'bold', 'Color', [0.8 0.5 0]);
    handles.indicators.eprimeSerial = text(ax, 0.75, 0.5, 'E-Prime: Init...', 'FontSize', 10, 'FontWeight', 'bold', 'Color', [0.8 0.5 0]);
end
function handles = createEEGPlot(handles, config)
    ax = nexttile([7 1]); title(ax, 'EEG Channels with Offset'); xlabel(ax, 'Time (samples)'); grid(ax, 'on');
    xlim(ax, [0 config.eeg.fs * config.plot.xRangeSec]); num_ch_eeg = 7; offset_val = 5000;
    handles.eeg.offset_vector = (1:num_ch_eeg) * offset_val;
    if config.plot.fixedYlim, ylim(ax, [0 offset_val * (num_ch_eeg + 1)]); end
    colors = [0.9 0.09 0.09; 0.9 0.45 0; 0.9 0.67 0; 0 0.72 0.18; 0 0.45 0.9; 0.36 0.18 0.9; 0.72 0.18 0.72];
    handles.eeg.lines = gobjects(num_ch_eeg,1);
    for i = 1:num_ch_eeg, handles.eeg.lines(i) = animatedline(ax, 'Color', colors(i,:), 'LineWidth', 1.5, 'MaximumNumPoints', config.plot.eegMaximumNumPoints); end
    handles.eeg.labels = gobjects(num_ch_eeg, 1);
    initial_x_pos = -0.02 * (config.eeg.fs * config.plot.xRangeSec);
    for i = 1:num_ch_eeg, handles.eeg.labels(i) = text(ax, initial_x_pos, i*offset_val, ['Ch ' num2str(i)], 'Color', colors(i,:), 'FontWeight', 'bold', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'middle', 'BackgroundColor', [0.96 0.96 0.96], 'Margin', 1); end
end
function handles = createTriggerPlot(handles, config)
    ax = nexttile; title(ax, 'Trigger (TCP / Serial / Numpad)'); xlabel(ax, 'Time (samples)'); ylabel(ax, 'Value'); grid(ax, 'on');
    xlim(ax, [0 config.eeg.fs * config.plot.xRangeSec]); ylim(ax, [0 10]); handles.trigger.ax = ax;
end
function handles = createFNIRSPlot(handles, config)
    num_pairs = size(config.fnirs.pairs, 1);
    handles.fnirs_figure = figure('Name', 'fNIRS Selected Pairs', 'NumberTitle', 'off');
    t_fnirs = tiledlayout(num_pairs, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(t_fnirs, 'Selected Emitter-Detector Pairs'); handles.fnirs.lines = gobjects(num_pairs, 2); handles.fnirs.pair_map = config.fnirs.pairs;
    for i = 1:num_pairs
        e_orig = config.fnirs.pairs(i, 1); d_orig = config.fnirs.pairs(i, 2);
        ax1 = nexttile; handles.fnirs.lines(i, 1) = animatedline(ax1, 'Color', 'r'); title(sprintf('E%d-D%d (850nm)', e_orig, d_orig)); grid on; xticklabels([]); ytickformat(ax1,'%.2f');
        ax2 = nexttile; handles.fnirs.lines(i, 2) = animatedline(ax2, 'Color', 'b'); title(sprintf('E%d-D%d (725nm)', e_orig, d_orig)); grid on; xticklabels([]); ytickformat(ax2,'%.2f');
    end
    handles.fnirs.emitter_map = cell(5, 1);
    for e_orig = 1:5
        rows = find(handles.fnirs.pair_map(:, 1) == e_orig);
        if ~isempty(rows), handles.fnirs.emitter_map{e_orig} = [rows, handles.fnirs.pair_map(rows, 2)]; end
    end
    handles.fnirs.all_axes = findall(handles.fnirs_figure, 'Type', 'axes');
end
function appState = plotQueuedTriggers(handles, appState)
    if ~isempty(appState.visualTriggerQueue)
        for i = 1:length(appState.visualTriggerQueue)
            event = appState.visualTriggerQueue(i);
            updateTriggerPlot(handles, event.sample, event.value);
        end
        appState.visualTriggerQueue = struct('value', {}, 'sample', {});
    end
end
function appState = updateGraphics(config, handles, appState, packetType)
    if packetType == config.eeg.id, appState = updateEEGPlot(config, handles, appState);
    else, appState = updateFNIRSPlot(config, handles, appState, packetType); end
    drawnow('limitrate');
    appState.plotData(packetType).x = []; appState.plotData(packetType).y = [];
end
function appState = updateEEGPlot(config, handles, appState)
    x_data = appState.plotData(config.eeg.id).x; y_data = appState.plotData(config.eeg.id).y;
    if config.filter.apply
        [y_data, appState.filter.zi_n60] = filter(config.filter.b_n60, config.filter.a_n60, y_data, appState.filter.zi_n60);
        [y_data, appState.filter.zi_n50] = filter(config.filter.b_n50, config.filter.a_n50, y_data, appState.filter.zi_n50);
        [y_data, appState.filter.zi_bp] = filter(config.filter.b_bp, config.filter.a_bp, y_data, appState.filter.zi_bp);
    end
    y_data = y_data + handles.eeg.offset_vector;
    for i = 1:size(y_data, 2), addpoints(handles.eeg.lines(i), x_data, y_data(:, i)); end
    ax_eeg = handles.eeg.lines(1).Parent;
    if ~isempty(x_data) && x_data(end) > ax_eeg.XLim(2)
        x_range = config.eeg.fs * config.plot.xRangeSec;
        new_xlim = [x_data(end) - x_range, x_data(end)];
        ax_eeg.XLim = new_xlim; handles.trigger.ax.XLim = new_xlim;
        all_texts = findall(handles.trigger.ax, 'Type', 'text');
        for k = 1:length(all_texts), if all_texts(k).Position(1) < new_xlim(1), delete(all_texts(k)); end, end
    end
    current_xlim = ax_eeg.XLim; label_x_pos = current_xlim(1) - 0.02 * diff(current_xlim);
    for i=1:length(handles.eeg.labels), handles.eeg.labels(i).Position(1) = label_x_pos; end
end
function appState = updateFNIRSPlot(config, handles, appState, packetType)
    x_data = appState.plotData(packetType).x; y_data = appState.plotData(packetType).y;
    if config.filter.apply, [y_data, appState.filter.zi_lp{packetType}] = filter(config.filter.b_lp, config.filter.a_lp, y_data, appState.filter.zi_lp{packetType}); end
    emitter_orig = packetType - 1; update_info = handles.fnirs.emitter_map{emitter_orig};
    if ~isempty(update_info)
        for i = 1:size(update_info, 1)
            pair_row_idx = update_info(i, 1); detector_orig = update_info(i, 2);
            addpoints(handles.fnirs.lines(pair_row_idx, 1), x_data, y_data(:, detector_orig));
            addpoints(handles.fnirs.lines(pair_row_idx, 2), x_data, y_data(:, detector_orig + 5));
        end
    end
    if ~isempty(x_data) && x_data(end) > config.fnirs.fs * config.plot.xRangeSec
        new_xlim = [x_data(end) - config.fnirs.fs * config.plot.xRangeSec, x_data(end)];
        set(handles.fnirs.all_axes, 'XLim', new_xlim);
    end
end
function updateTriggerPlot(handles, xCoord, triggerValue)
    text(handles.trigger.ax, xCoord, 5, num2str(triggerValue), 'FontSize', 12, 'FontWeight', 'bold', 'HorizontalAlignment', 'center', 'Color', 'r');
end
function updateStatusIndicators(handles, appState)
    if ~isempty(appState.tcp) && isvalid(appState.tcp)
        if appState.tcp.Connected, set(handles.indicators.tcp, 'String', 'TCP: Connected', 'Color', [0 0.6 0.2]);
        else, set(handles.indicators.tcp, 'String', 'TCP: Listening...', 'Color', [0.9 0.6 0]); end
    else, set(handles.indicators.tcp, 'String', 'TCP: Error/Off', 'Color', [0.8 0 0]); end
    if ~isempty(appState.s) && isvalid(appState.s), set(handles.indicators.deviceSerial, 'String', 'Device: Connected', 'Color', [0 0.6 0.2]);
    else, set(handles.indicators.deviceSerial, 'String', 'Device: Disconnected', 'Color', [0.8 0 0]); end
    if ~isempty(appState.trigger_s) && isvalid(appState.trigger_s), set(handles.indicators.eprimeSerial, 'String', 'E-Prime: Connected', 'Color', [0 0.6 0.2]);
    else, set(handles.indicators.eprimeSerial, 'String', 'E-Prime: Disconnected', 'Color', [0.8 0 0]); end
end
%% =======================================================================
%                      6. UTILITY & CLEANUP
% ========================================================================
function writeLogEntry(fid, config, packetType, channelData, sampleCounters, triggerValue)
    current_time_str = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS'));
    if packetType == config.eeg.id, typeName = 'EEG'; counter = sampleCounters(packetType);
    else, typeName = ['fNIRS_E' num2str(packetType-1)]; counter = sampleCounters(packetType); end
    log_data = strings(1, 10); log_data(1:length(channelData)) = string(channelData);
    fprintf(fid, '%s,%s,%d,%d,%s\n', current_time_str, typeName, counter, triggerValue, strjoin(log_data, ','));
end
function channelData = extractType1Data(packet)
    channelData = zeros(1, 7);
    for i = 1:7
        idx = 3 * (i - 1) + 4; val = bitor(bitor(bitshift(packet(idx), 16), bitshift(packet(idx + 1), 8)), packet(idx + 2));
        if val > 8388607, val = val - 16777216; end
        channelData(i) = val;
    end
end
function channelData = extractType2To6Data(packet)
    channelData = zeros(1, 10);
    for i = 1:10
        idx = 2 * (i - 1) + 5; channelData(i) = bitor(bitshift(packet(idx), 8), packet(idx + 1));
    end
end
function cleanup(appState, fid, handles)
    disp('Cleaning up resources...');
    if fid ~= -1, fclose(fid); end
    if isfield(appState, 's') && ~isempty(appState.s) && isvalid(appState.s), delete(appState.s); end
    if isfield(appState, 'trigger_s') && ~isempty(appState.trigger_s) && isvalid(appState.trigger_s), delete(appState.trigger_s); end
    if isfield(appState, 'tcp') && ~isempty(appState.tcp) && isvalid(appState.tcp), delete(appState.tcp); end
    if nargin > 2 && isfield(handles, 'eeg_figure') && isgraphics(handles.eeg_figure), close(handles.eeg_figure); end
    if nargin > 2 && isfield(handles, 'fnirs_figure') && isgraphics(handles.fnirs_figure), close(handles.fnirs_figure); end
    disp('Cleanup complete. Program ended.');
end