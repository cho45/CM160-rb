#!/usr/bin/env ruby
# coding: ascii-8bit

require "serialport"

SerialPort.class_eval do
	TCGETS2 = 0x802c542a
	TCSETS2 = 0x402c542b
	CBAUD   = 0x100f
	BOTHER  = 0x1000

	# struct termios2 {
	Termios2 = Struct.new(*[
		:c_iflag,
		:c_oflag,
		:c_cflag,
		:c_lflag,
		:c_line,
		(0...19).map {|n| # c_cc[NCCS] NCCS = 19
			"c_cc_#{n}".to_sym
		},
		:c_ispeed,
		:c_ospeed
	].flatten);
	Termios2::FORMAT = "I!I!I!I!CC19I!I!"
	Termios2::FORMAT_POINTER = "P44"
	# }

	def set_custom_baudrate(baud)
		tio = Termios2.new
		tio.each_pair {|m,_| tio[m] = 0 }

		# read
		v = tio.values.flatten.pack(Termios2::FORMAT)
		self.ioctl(TCGETS2, v)
		tio = Termios2.new(*v.unpack(Termios2::FORMAT))

		# write
		tio.c_cflag &= ~CBAUD
		tio.c_cflag |= BOTHER
		tio.c_ispeed = baud
		tio.c_ospeed = baud
		v = tio.values.flatten.pack(Termios2::FORMAT)
		self.ioctl(TCSETS2, v)

		# read
		v = tio.values.flatten.pack(Termios2::FORMAT)
		self.ioctl(TCGETS2, v)
		tio = Termios2.new(*v.unpack(Termios2::FORMAT))
		if tio.c_ispeed == baud && tio.c_ospeed == baud
			true
		else
			raise "failed to set baudrate expected:#{baud} but set:#{tio.c_ispeed}/#{tio.c_ospeed}"
		end
	end
end

require "logger"
class CM160
	GET_HISTORY = "\x5A"
	GET_CURRENT = "\xA5"

	class Data
		attr_reader :year
		attr_reader :month
		attr_reader :day
		attr_reader :hour
		attr_reader :min
		attr_reader :current

		def initialize(frame)
			unless frame.size == 11
				raise "invalid frame length"
			end

			sum = frame.pop
			unless frame.reduce {|r,i| r + i } & 0xff == sum
				raise "invalid check sum"
			end

			@year  = frame[1] + 2000
			@month = frame[2] & 0b1111 ## XXX 0b11110000 unknown bit
			@day   = frame[3]
			@hour  = frame[4]
			@min   = frame[5]

			@current = ( frame[8] + (frame[9] << 8) ) * 0.07;
		end

		def time
			Time.local(@year, @month, @day, @hour, @min)
		end
	end

	attr_reader :logger

	def initialize(port:, logger: nil)
		@port = SerialPort.new(
			port,
			230400,
			8,
			1,
			0
		)
		@port.flow_control = SerialPort::NONE
		@port.set_encoding(Encoding::BINARY)
		@port.set_custom_baudrate(250000)

		@logger = logger
		unless @logger
			@logger= Logger.new(STDOUT)
			@logger.level = Logger::DEBUG
		end
	end

	def get_data(&block)
		loop do
			data = @port.readpartial(11)

			case data
			when /^\xA9IDTCMV001\x01/
				@logger.debug :GET_HISTORY
				@port << GET_HISTORY
				@port.flush
			when /^\xA9IDTWAITPCR/
				@logger.debug :GET_CURRENT
				@port << GET_CURRENT
				@port.flush
			when /^\x59/, /^\x51/
				## parser from cm160Server.py is translated to ruby by cho45
				## Copyright 2011 Paul Austen
				## This program is distributed under the terms of the GNU General Public License

				begin
					data = Data.new(data.unpack("C*"))
				rescue => e
					warn e
					next
				end
				@logger.debug data.inspect

				block.call(data)

			else
				@logger.warn "unknown message %p (%d)" % [ data, data.size ]
			end
		end
	end
end

if $0 == __FILE__
	AC_VOLTAGE = 100
	meter = CM160.new(port: "/dev/ttyUSB0")
	meter.get_data do |data|
		if Time.now - data.time > 120
			meter.logger.warn "old date... skip #{time}"
			next
		end

		watt = data.current * AC_VOLTAGE
		meter.logger.debug "%.2fA * %dV = %dW" % [data.current, AC_VOLTAGE, watt]
	end
end
