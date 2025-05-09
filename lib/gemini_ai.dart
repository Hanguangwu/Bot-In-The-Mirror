import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'openai_service.dart';
import 'model.dart';

class GeminiChatBot extends StatefulWidget {
  const GeminiChatBot({super.key});
  @override
  State<GeminiChatBot> createState() => _GeminiChatBotState();
}

class _GeminiChatBotState extends State<GeminiChatBot> {
  TextEditingController promprController = TextEditingController();
  final OpenAIService openAIService = OpenAIService();
  final List<ModelMessage> prompt = [];

  Future<void> sendMessage() async {
    final message = promprController.text;
    // for prompt
    setState(() {
      promprController.clear();
      prompt.add(
        ModelMessage(isPrompt: true, message: message, time: DateTime.now()),
      );
    });
    // for respond
    final content = message;
    final response = await openAIService.chatGPTAPI(content);
    setState(() {
      prompt.add(
        ModelMessage(
          isPrompt: false,
          message: response,
          time: DateTime.now(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue[100],
      appBar: AppBar(
        elevation: 3,
        backgroundColor: Colors.blue[100],
        title: const Text("AI ChatBot"),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: prompt.length,
              itemBuilder: (context, index) {
                final message = prompt[index];
                return userPrompt(
                  isPrompt: message.isPrompt,
                  message: message.message,
                  date: DateFormat('hh:mm a').format(message.time),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(25),
            child: Row(
              children: [
                Expanded(
                  flex: 20,
                  child: TextField(
                    controller: promprController,
                    style: const TextStyle(color: Colors.black, fontSize: 20),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      hintText: "Enter a prompt here",
                    ),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    sendMessage();
                  },
                  child: const CircleAvatar(
                    radius: 29,
                    backgroundColor: Colors.green,
                    child: Icon(Icons.send, color: Colors.white, size: 32),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Container userPrompt({
    required final bool isPrompt,
    required String message,
    required String date,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      margin: const EdgeInsets.symmetric(
        vertical: 15,
      ).copyWith(left: isPrompt ? 80 : 15, right: isPrompt ? 15 : 80),
      decoration: BoxDecoration(
        color: isPrompt ? Colors.green : Colors.grey,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: isPrompt ? const Radius.circular(20) : Radius.zero,
          bottomRight: isPrompt ? Radius.zero : const Radius.circular(20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // for prompt and response
          Text(
            message,
            style: TextStyle(
              fontWeight: isPrompt ? FontWeight.bold : FontWeight.normal,
              fontSize: 18,
              color: isPrompt ? Colors.white : Colors.black,
            ),
          ),
          // for prompt and response time
          Text(
            date,
            style: TextStyle(
              fontSize: 14,
              color: isPrompt ? Colors.white : Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}
