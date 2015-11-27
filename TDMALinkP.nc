#include <Timer.h>
#include <printf.h>

#include "messages.h"

#define SYNC_SLOT 0
#define JOIN_SLOT 1

module TDMALinkP {
	provides interface SplitControl as Control;
	provides interface AMSend;
	provides interface Receive;

	uses {
		interface AMPacket;
		interface SplitControl as AMControl;

		interface TimeSyncAMSend<T32khz, uint32_t> as SyncSnd;
		interface Receive as SyncRcv;
        interface TimeSyncPacket<T32khz, uint32_t> as TSPacket;

		interface AMSend as JoinReqSnd;
		interface Receive as JoinReqRcv;

		interface AMSend as JoinAnsSnd;
		interface Receive as JoinAnsRcv;

		interface AMSend as DataSnd;

		interface SlotScheduler;
	}
}

implementation {

	bool isMaster;

	bool syncReceived = FALSE;

	bool hasJoined = FALSE;
	uint8_t assignedSlot;

	// Sync beacon packet
	SyncMsg* syncMsg;
	message_t syncBuf;
	bool syncSending = FALSE;

	// Join request packet
	message_t joinReqBuf;
	JoinReqMsg* joinReqMsg;
	bool joinReqSending = FALSE;

	// Join answer packet
	message_t joinAnsBuf;
	JoinAnsMsg* joinAnsMsg;
	bool joinAnsSending = FALSE;

	// Data packet
	am_addr_t dataAddr;
	message_t *dataMsg;
	uint8_t dataLen;
	bool dataReady = FALSE;

	void startListen();
	void stopListen();

	void sendSyncBeacon();
	void sendJoinRequest();
	void sendJoinAnswer(am_addr_t slave, uint8_t slot);
	void sendData();

	command error_t Control.start() {
		isMaster = (TOS_NODE_ID == 1);

		syncMsg = call SyncSnd.getPayload(&joinAnsBuf, sizeof(SyncMsg));
		joinReqMsg = call JoinReqSnd.getPayload(&joinAnsBuf, sizeof(JoinReqMsg));
		joinAnsMsg = call JoinAnsSnd.getPayload(&joinAnsBuf, sizeof(JoinAnsMsg));

		call AMControl.start();

		//Start slot scheduler and schedule first slot
		call SlotScheduler.start(0, SYNC_SLOT);
		//TODO: signal per interfaccia splitcontrol
		return SUCCESS;
	}

	command error_t Control.stop() {
		//TODO: signal per interfaccia splitcontrol
		return SUCCESS;
	}

	event void SlotScheduler.slotStarted(uint8_t slot) {
		printf("Slot %d started\n", slot);
		if(isMaster) {
			if(slot == SYNC_SLOT)
				sendSyncBeacon();
			return;
		}

		if(slot == SYNC_SLOT)
			syncReceived = FALSE; //TODO: Listen for sync
		else if (slot == JOIN_SLOT)
			sendJoinRequest();
		else
			sendData();
	}

	event void AMControl.startDone(error_t err) {
		printf("Radio ON\n");
	}

	event uint8_t SlotScheduler.slotEnded(uint8_t slot) {
		printf("Slot %d ended\n", slot);
		if(isMaster) {
			if(slot == SYNC_SLOT)
				return JOIN_SLOT;
			else if(slot == JOIN_SLOT)
				return 7; //FIXME: schedule data listening slot
			else
				return SYNC_SLOT;
		}

		if(slot == SYNC_SLOT) {
			if(syncReceived == FALSE) {
				//TODO: count missed sync and decide for resync mode
				return SYNC_SLOT;
			} else {
				if(hasJoined)
					return assignedSlot;
				else
					return JOIN_SLOT;
			}
		}

		if(slot == JOIN_SLOT && hasJoined == TRUE)
			return assignedSlot;
		else
			return SYNC_SLOT;
	}

	event void AMControl.stopDone(error_t err) {
		printf("Radio OFF\n");
	}

	void sendSyncBeacon() {
		error_t status;
		if (!syncSending) {
			uint32_t epoch_time = call SlotScheduler.getEpochTime();
			printf("Sending sync beacon with reference time %lu\n", epoch_time);
			status = call SyncSnd.send(AM_BROADCAST_ADDR, &syncBuf, sizeof(SyncMsg), epoch_time);
			if (status == SUCCESS) {
				syncSending = TRUE;
			} else {
				printf("Sync beacon sending failed\n");
			}
		}
	}

	event void SyncSnd.sendDone(message_t* msg, error_t error) {
		syncSending = FALSE;
		if (error != SUCCESS) {
			printf("Sync beacon transmission failed\n");
		}
	}

	event message_t* SyncRcv.receive(message_t* msg, void* payload, uint8_t length) {
		if (length != sizeof(SyncMsg))
			return msg;

		if (call TSPacket.isValid(msg) && length == sizeof(SyncMsg)) {
			uint32_t ref_time = call TSPacket.eventTime(msg);
			// synchronize the epoch start time (converted to our local time reference frame)
			printf("Synchonizing slot scheduler with new master time %lu (was %lu)\n",ref_time, call SlotScheduler.getEpochTime());
			call SlotScheduler.syncEpochTime(ref_time);
			syncReceived = TRUE;
		}

		return msg;
	}

	void sendJoinRequest() {
		error_t status;
		if (!joinReqSending) {
			printf("Sending join request\n");
			status = call JoinReqSnd.send(AM_BROADCAST_ADDR, &joinReqBuf, sizeof(JoinReqMsg));
			if (status == SUCCESS) {
				joinReqSending = TRUE;
			} else {
				printf("Join request sending failed\n");
			}
		}
	}

	event void JoinReqSnd.sendDone(message_t* msg, error_t error) {
		joinReqSending = FALSE;
		if (error != SUCCESS) {
			printf("Join request transmission failed\n");
		}
	}

	event message_t* JoinReqRcv.receive(message_t* msg, void* payload, uint8_t length) {
		am_addr_t from;		
		if (length != sizeof(JoinReqMsg))
			return msg;

		joinReqMsg = (JoinReqMsg*) payload;

		from = call AMPacket.source(msg);

		printf("Join request received from %d\n", from);

		//TODO: Allocate slot

		sendJoinAnswer(from, 7);

		return msg;
	}

	void sendJoinAnswer(am_addr_t slave, uint8_t slot) {
		error_t status;
		if (!joinReqSending) {
			joinAnsMsg->slot = slot;
			printf("Sending join answer to %d\n", slave);
			status = call JoinAnsSnd.send(slave, &joinAnsBuf, sizeof(JoinAnsMsg));
			if (status == SUCCESS) {
				joinAnsSending = TRUE;
			} else {
				printf("Join answer sending failed\n");
			}
		}
	}

	event void JoinAnsSnd.sendDone(message_t* msg, error_t error) {
		joinAnsSending = FALSE;
		if (error != SUCCESS) {
			printf("Join answer transmission failed\n");
		}
	}

	event message_t* JoinAnsRcv.receive(message_t* msg, void* payload, uint8_t length) {
		if (length != sizeof(JoinAnsMsg))
			return msg;

		joinAnsMsg = (JoinAnsMsg*) payload;

		assignedSlot = joinAnsMsg->slot;

		printf("Join completed to slot %d\n", assignedSlot);
		
		hasJoined = TRUE;

		return msg;
	}

	/////////////////////////// SLAVE DATA TRANSMISSION ///////////////////////////

	void sendData() {
		if(dataReady) {
			printf("Sending data\n");
			call DataSnd.send(dataAddr, dataMsg, dataLen);
		} else {
			printf("No data to transmit\n");
		}
	}

	command error_t AMSend.cancel(message_t *msg) {
		return call AMSend.cancel(msg);
	}

	command void* AMSend.getPayload(message_t *msg, uint8_t len) {
		return call AMSend.getPayload(msg, len);
	}

	command uint8_t AMSend.maxPayloadLength() {
		return call AMSend.maxPayloadLength();
	}

	command error_t AMSend.send(am_addr_t addr, message_t *msg, uint8_t len) {
		if(dataReady)
			return BUSY;

		dataAddr = addr;
		dataMsg = msg;
		dataLen = len;

		dataReady = TRUE;

		return SUCCESS;
	}

	event void DataSnd.sendDone(message_t *msg, error_t error) {
		dataReady = FALSE;
		signal AMSend.sendDone(msg, error);
	}
}
